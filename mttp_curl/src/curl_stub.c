// gaato/mttp_curl: libcurl's multi interface on a thread of its own.
//
// Each engine (one per CurlBackend) owns a CURLM and one pthread that loops
// over curl_multi_poll, a command queue and curl_multi_perform. MoonBit never
// calls into curl itself: it queues commands (add, unpause, remove, shutdown)
// and wakes the thread with curl_multi_wakeup, because an easy handle in a
// multi handle may only be touched by the thread that drives the multi.
//
// The thread never calls into MoonBit either, since the MoonBit runtime is
// not thread-safe. Every curl callback only touches the C memory of its
// transfer, under the transfer's mutex, and then signals the transfer's
// notification descriptor: an eventfd on Linux, a pipe elsewhere. MoonBit
// holds a dup of its read end in a core/async RawFd and waits on it; a read
// drains it, and MoonBit then reads a snapshot of the transfer's state. The
// dup lets MoonBit close its end whenever it is unwound without racing the
// thread, which keeps both of its own ends open until it frees the transfer:
// a reused descriptor number is never written, and a pipe's write never
// raises SIGPIPE, since its read end stays open.
//
// Lifetimes are reference counts, so that no side frees memory another
// still points at. An engine is held by MoonBit's CurlBackend (through a
// GC-managed box whose finalizer lets go), by each transfer made on it and
// by its thread until the thread ends; a transfer is held by MoonBit's
// Exchange (a box likewise), by the multi handle while it is added, and by
// each queued command naming it. Whoever lets go last frees. After
// shutdown the engine refuses new transfers itself, so MoonBit's closed
// flag is a shortcut, not what keeps memory safe.
//
// libcurl 7.85 or later: CURLOPT_PROTOCOLS_STR (7.85), CURLOPT_PREREQFUNCTION
// and CURLOPT_MAXLIFETIME_CONN (7.80). CURLINFO_POSTTRANSFER_TIME_T (8.10)
// is used when present.

#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/eventfd.h>
#endif

#include "moonbit.h"

#if LIBCURL_VERSION_NUM >= 0x080a00
#define HAVE_POSTTRANSFER 1
#endif

// State bits returned by mttp_curl_transfer_state.
enum {
  ST_PREREQ = 1,          // connected, the request is about to be sent
  ST_HEAD = 2,            // the final response head is complete
  ST_DONE = 4,            // curl finished the transfer (result says how)
  ST_WANTS_BODY = 8,      // the upload is paused for want of bytes
  ST_BODY = 16,           // response body bytes are buffered
  ST_HEAD_TOO_LARGE = 32, // the response head passed the limit
  ST_CLOSED = 64,         // ended by the engine's shutdown
  ST_SENT = 128,          // the whole request was sent
  ST_FIRST_BYTE = 256,    // the first response byte (a status line) arrived
  ST_NEW_CONN = 512,      // with PREREQ: this transfer opened its connection
};

typedef struct transfer transfer;

typedef enum { CMD_ADD, CMD_UNPAUSE, CMD_REMOVE, CMD_SHUTDOWN } cmd_kind;

typedef struct cmd {
  cmd_kind kind;
  transfer *t;
  struct cmd *next;
} cmd;

typedef struct engine {
  CURLM *multi;
  pthread_mutex_t qlock;
  // Under qlock.
  cmd *qhead, *qtail;
  int shutdown;     // no new transfers; the thread ends when idle
  int thread_done;  // the thread has ended and reads no more commands
  int refs;
  transfer *added;  // in the multi handle; the thread's own list
} engine;

struct transfer {
  engine *e;
  CURL *easy;
  struct curl_slist *headers;
  int notify_r;   // the thread's ends of the notification descriptor (one
  int notify_w;   // eventfd on Linux); MoonBit waits on a dup of notify_r
  int added;      // the thread's own fields: in the multi handle, and its
  transfer *prev, *next;  // place in the engine's list
  pthread_mutex_t lock;
  // Under lock from here on.
  int refs;
  int released;   // MoonBit asked for the transfer to end
  int state;
  int paused_write;
  int paused_read;
  int up_abandoned;
  int32_t status;
  int32_t version;
  int32_t result;
  int32_t connect_code;
  char errbuf[CURL_ERROR_SIZE];
  // The final response head: the status line and the field lines.
  char *head;
  size_t head_len, head_max;
  int head_open;  // between a status line and its blank line
  // Response body bytes not yet read by MoonBit: [body_off, body_len).
  uint8_t *body;
  size_t body_off, body_len, body_cap;
  // Request body bytes not yet given to curl: [up_off, up_len).
  uint8_t *up;
  size_t up_off, up_len;
  int up_eof;
};

static pthread_once_t global_once = PTHREAD_ONCE_INIT;
static void global_init(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

// Wakes MoonBit. A full pipe already has a wake-up pending, so EAGAIN is fine.
static void notify(transfer *t) {
#if defined(__linux__)
  uint64_t one = 1;
  const void *p = &one;
  size_t n = sizeof one;
#else
  const char one = 1;
  const void *p = &one;
  size_t n = 1;
#endif
  ssize_t r;
  do {
    r = write(t->notify_w, p, n);
  } while (r < 0 && errno == EINTR);
}

static int open_notify(transfer *t) {
#if defined(__linux__)
  int fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  t->notify_r = t->notify_w = fd;
  return fd < 0 ? -1 : 0;
#else
  int fds[2];
  if (pipe(fds) != 0) return -1;
  for (int i = 0; i < 2; i++) {
    fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
    fcntl(fds[i], F_SETFD, FD_CLOEXEC);
  }
  t->notify_r = fds[0];
  t->notify_w = fds[1];
  return 0;
#endif
}

static void close_notify(transfer *t) {
  close(t->notify_r);
  if (t->notify_w != t->notify_r) close(t->notify_w);
}

static void engine_ref(engine *e) {
  pthread_mutex_lock(&e->qlock);
  e->refs++;
  pthread_mutex_unlock(&e->qlock);
}

static void engine_unref(engine *e) {
  pthread_mutex_lock(&e->qlock);
  int left = --e->refs;
  pthread_mutex_unlock(&e->qlock);
  if (left == 0) {
    // The thread held a reference until it ended, so nothing drives the
    // multi handle any more, and no transfer is in it.
    curl_multi_cleanup(e->multi);
    pthread_mutex_destroy(&e->qlock);
    free(e);
  }
}

static void transfer_ref(transfer *t) {
  pthread_mutex_lock(&t->lock);
  t->refs++;
  pthread_mutex_unlock(&t->lock);
}

static void transfer_unref(transfer *t) {
  pthread_mutex_lock(&t->lock);
  int left = --t->refs;
  pthread_mutex_unlock(&t->lock);
  if (left == 0) {
    // Not in the multi handle (that holds a reference), so no callback runs.
    engine *e = t->e;
    curl_easy_cleanup(t->easy);
    curl_slist_free_all(t->headers);
    close_notify(t);
    free(t->head);
    free(t->body);
    free(t->up);
    pthread_mutex_destroy(&t->lock);
    free(t);
    engine_unref(e);
  }
}

static void mark_closed(transfer *t) {
  pthread_mutex_lock(&t->lock);
  t->state |= ST_DONE | ST_CLOSED;
  t->result = CURLE_ABORTED_BY_CALLBACK;
  pthread_mutex_unlock(&t->lock);
  notify(t);
}

// Queues a command for the thread. The caller holds a reference to `e`,
// and the command one to `t`, so neither is freed under it. Once the thread
// has ended nobody reads the queue: a transfer it would have added ends as
// Closed at once, and the other commands have nothing left to act on.
static void enqueue(engine *e, cmd_kind kind, transfer *t) {
  if (t) transfer_ref(t);
  pthread_mutex_lock(&e->qlock);
  if (e->thread_done) {
    pthread_mutex_unlock(&e->qlock);
    if (t) {
      if (kind == CMD_ADD) mark_closed(t);
      transfer_unref(t);
    }
    return;
  }
  cmd *c = malloc(sizeof *c);
  c->kind = kind;
  c->t = t;
  c->next = NULL;
  if (e->qtail) e->qtail->next = c; else e->qhead = c;
  e->qtail = c;
  pthread_mutex_unlock(&e->qlock);
  curl_multi_wakeup(e->multi);
}

// ---------------------------------------------------------------- callbacks

static size_t on_header(char *buf, size_t size, size_t n, void *arg) {
  transfer *t = arg;
  size_t len = size * n;
  pthread_mutex_lock(&t->lock);
  if (t->state & ST_HEAD) {
    // Trailers: not exposed (Backend responses carry no trailers).
    pthread_mutex_unlock(&t->lock);
    return len;
  }
  int first = !(t->state & ST_FIRST_BYTE);
  t->state |= ST_FIRST_BYTE;
  if (len >= 5 && memcmp(buf, "HTTP/", 5) == 0) {
    // A new response block: an informational one before it is dropped.
    t->head_len = 0;
    t->head_open = 1;
    const char *sp = memchr(buf, ' ', len);
    int32_t status = 0;
    if (sp) {
      for (const char *p = sp + 1; p < buf + len && *p >= '0' && *p <= '9'; p++)
        status = status * 10 + (*p - '0');
    }
    t->status = status;
  }
  if (t->head_len + len > t->head_max) {
    t->state |= ST_HEAD_TOO_LARGE;
    pthread_mutex_unlock(&t->lock);
    notify(t);
    return 0;  // CURLE_WRITE_ERROR ends the transfer
  }
  memcpy(t->head + t->head_len, buf, len);
  t->head_len += len;
  int blank = (len == 2 && buf[0] == '\r') || (len == 1 && buf[0] == '\n');
  int finished = 0;
  if (blank && t->head_open) {
    t->head_open = 0;
    if (t->status >= 200) {
      long v = 0;
      curl_easy_getinfo(t->easy, CURLINFO_HTTP_VERSION, &v);
      t->version = (int32_t)v;
      t->state |= ST_HEAD;
      finished = 1;
    }
  }
  pthread_mutex_unlock(&t->lock);
  if (finished || first) notify(t);
  return len;
}

static size_t on_body(char *buf, size_t size, size_t n, void *arg) {
  transfer *t = arg;
  size_t len = size * n;
  pthread_mutex_lock(&t->lock);
  size_t held = t->body_len - t->body_off;
  if (held > 0 && held + len > t->body_cap) {
    // Full: curl delivers the same bytes again after the unpause that
    // mttp_curl_transfer_read queues once MoonBit has drained the buffer.
    t->paused_write = 1;
    pthread_mutex_unlock(&t->lock);
    return CURL_WRITEFUNC_PAUSE;
  }
  if (t->body_off > 0) {
    memmove(t->body, t->body + t->body_off, held);
    t->body_len = held;
    t->body_off = 0;
  }
  if (t->body_len + len > t->body_cap) {
    // A single delivery larger than the whole buffer (curl's are at most
    // CURLOPT_BUFFERSIZE): grow rather than stall for ever.
    t->body_cap = t->body_len + len;
    t->body = realloc(t->body, t->body_cap);
  }
  memcpy(t->body + t->body_len, buf, len);
  t->body_len += len;
  t->state |= ST_BODY;
  pthread_mutex_unlock(&t->lock);
  notify(t);
  return len;
}

static size_t on_read(char *buf, size_t size, size_t n, void *arg) {
  transfer *t = arg;
  size_t room = size * n;
  pthread_mutex_lock(&t->lock);
  if (t->up_abandoned) {
    // A final response came first: the rest of the body is never sent, and
    // the transfer is removed unfinished, so its connection is not reused.
    t->paused_read = 1;
    pthread_mutex_unlock(&t->lock);
    return CURL_READFUNC_PAUSE;
  }
  size_t held = t->up_len - t->up_off;
  if (held > 0) {
    size_t k = held < room ? held : room;
    memcpy(buf, t->up + t->up_off, k);
    t->up_off += k;
    if (t->up_off == t->up_len) {
      t->up_off = t->up_len = 0;
    }
    pthread_mutex_unlock(&t->lock);
    return k;
  }
  if (t->up_eof) {
    pthread_mutex_unlock(&t->lock);
    return 0;
  }
  t->paused_read = 1;
  t->state |= ST_WANTS_BODY;
  pthread_mutex_unlock(&t->lock);
  notify(t);
  return CURL_READFUNC_PAUSE;
}

static int on_prereq(void *arg, char *remote_ip, char *local_ip, int remote_port,
                     int local_port) {
  (void)remote_ip;
  (void)local_ip;
  (void)remote_port;
  (void)local_port;
  transfer *t = arg;
  long connects = 0;
  curl_easy_getinfo(t->easy, CURLINFO_NUM_CONNECTS, &connects);
  pthread_mutex_lock(&t->lock);
  t->state |= ST_PREREQ;
  if (connects > 0) t->state |= ST_NEW_CONN;
  pthread_mutex_unlock(&t->lock);
  notify(t);
  return CURL_PREREQFUNC_OK;
}

#ifdef HAVE_POSTTRANSFER
// Called by curl on the thread while a transfer runs: notes the moment the
// whole request has been sent, so that a failure or deadline before the
// response head says Head rather than Write. Without it (libcurl before
// 8.10) every failure after the prereq callback says Write.
static int on_progress(void *arg, curl_off_t dltotal, curl_off_t dlnow,
                       curl_off_t ultotal, curl_off_t ulnow) {
  (void)dltotal;
  (void)dlnow;
  (void)ultotal;
  (void)ulnow;
  transfer *t = arg;
  pthread_mutex_lock(&t->lock);
  // Only a request on a ready connection can have been sent.
  int known = (t->state & ST_SENT) || !(t->state & ST_PREREQ);
  pthread_mutex_unlock(&t->lock);
  if (!known) {
    curl_off_t sent_at = 0;
    curl_easy_getinfo(t->easy, CURLINFO_POSTTRANSFER_TIME_T, &sent_at);
    if (sent_at > 0) {
      pthread_mutex_lock(&t->lock);
      t->state |= ST_SENT;
      pthread_mutex_unlock(&t->lock);
      notify(t);
    }
  }
  return 0;
}
#endif

// --------------------------------------------------------------- the thread

static void link_added(transfer *t) {
  engine *e = t->e;
  transfer_ref(t);
  t->added = 1;
  t->prev = NULL;
  t->next = e->added;
  if (e->added) e->added->prev = t;
  e->added = t;
}

static void unlink_added(transfer *t) {
  engine *e = t->e;
  if (!t->added) return;
  curl_multi_remove_handle(e->multi, t->easy);
  if (t->prev) t->prev->next = t->next; else e->added = t->next;
  if (t->next) t->next->prev = t->prev;
  t->prev = t->next = NULL;
  t->added = 0;
  transfer_unref(t);  // the multi handle's reference: last, it may free t
}

static void finish(transfer *t, int32_t result, int closed) {
  long connect_code = 0;
  curl_easy_getinfo(t->easy, CURLINFO_HTTP_CONNECTCODE, &connect_code);
#ifdef HAVE_POSTTRANSFER
  curl_off_t sent_at = 0;
  curl_easy_getinfo(t->easy, CURLINFO_POSTTRANSFER_TIME_T, &sent_at);
#endif
  pthread_mutex_lock(&t->lock);
  t->state |= ST_DONE;
  if (closed) t->state |= ST_CLOSED;
#ifdef HAVE_POSTTRANSFER
  if (sent_at > 0 && (t->state & ST_PREREQ)) t->state |= ST_SENT;
#endif
  t->result = result;
  t->connect_code = (int32_t)connect_code;
  pthread_mutex_unlock(&t->lock);
  notify(t);
  unlink_added(t);
}

static void *engine_main(void *arg) {
  engine *e = arg;
  int shutting = 0;
  for (;;) {
    pthread_mutex_lock(&e->qlock);
    cmd *c = e->qhead;
    e->qhead = e->qtail = NULL;
    if (e->shutdown) shutting = 1;
    pthread_mutex_unlock(&e->qlock);
    while (c) {
      cmd *next = c->next;
      transfer *t = c->t;
      switch (c->kind) {
        case CMD_ADD:
          if (shutting) {
            finish(t, CURLE_ABORTED_BY_CALLBACK, 1);
          } else if (curl_multi_add_handle(e->multi, t->easy) == CURLM_OK) {
            link_added(t);
          } else {
            finish(t, CURLE_FAILED_INIT, 0);
          }
          break;
        case CMD_UNPAUSE:
          if (t->added) curl_easy_pause(t->easy, CURLPAUSE_CONT);
          break;
        case CMD_REMOVE:
          unlink_added(t);
          break;
        case CMD_SHUTDOWN:
          break;
      }
      if (t) transfer_unref(t);  // the command's reference
      free(c);
      c = next;
    }
    if (shutting) {
      // End every transfer still in the multi handle; their remove commands
      // follow from MoonBit, and the thread stays until they have.
      // No transfer is left in the multi handle now. The thread ends once
      // the queue is empty too; deciding so under the lock means a command
      // queued later finds thread_done set.
      while (e->added) finish(e->added, CURLE_ABORTED_BY_CALLBACK, 1);
      pthread_mutex_lock(&e->qlock);
      int done = e->qhead == NULL;
      if (done) e->thread_done = 1;
      pthread_mutex_unlock(&e->qlock);
      if (done) break;
    }
    int running = 0;
    curl_multi_perform(e->multi, &running);
    CURLMsg *msg;
    int left;
    while ((msg = curl_multi_info_read(e->multi, &left))) {
      if (msg->msg != CURLMSG_DONE) continue;
      transfer *t = NULL;
      curl_easy_getinfo(msg->easy_handle, CURLINFO_PRIVATE, (char **)&t);
      if (t) finish(t, msg->data.result, 0);
    }
    curl_multi_poll(e->multi, NULL, 0, 1000, NULL);
  }
  engine_unref(e);  // the thread's reference
  return NULL;
}

// ------------------------------------------------------- the MoonBit side

// What MoonBit holds: GC-managed boxes, each owning one reference. The
// pointer inside is NULL when making the engine or transfer failed.
typedef struct { engine *e; } engine_box;
typedef struct { transfer *t; } transfer_box;

static void engine_close(engine *e) {
  pthread_mutex_lock(&e->qlock);
  e->shutdown = 1;
  pthread_mutex_unlock(&e->qlock);
  enqueue(e, CMD_SHUTDOWN, NULL);
}

// A CurlBackend dropped without close is closed here.
static void engine_box_finalize(void *self) {
  engine_box *b = self;
  if (b->e) {
    engine_close(b->e);
    engine_unref(b->e);
  }
}

// An Exchange dropped without release is released here.
static void transfer_box_finalize(void *self) {
  transfer_box *b = self;
  if (!b->t) return;
  transfer *t = b->t;
  pthread_mutex_lock(&t->lock);
  int released = t->released;
  t->released = 1;
  pthread_mutex_unlock(&t->lock);
  if (!released) enqueue(t->e, CMD_REMOVE, t);
  transfer_unref(t);
}

MOONBIT_FFI_EXPORT int32_t mttp_curl_engine_is_null(engine_box *b) { return b->e == NULL; }

MOONBIT_FFI_EXPORT int32_t mttp_curl_transfer_is_null(transfer_box *b) { return b->t == NULL; }

// Bit 1: HTTP/2, bit 2: HTTP/3, bit 4: the moment a request is sent is
// known (CURLINFO_POSTTRANSFER_TIME_T, libcurl 8.10).
MOONBIT_FFI_EXPORT int32_t mttp_curl_features(void) {
  pthread_once(&global_once, global_init);
  curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
  int32_t bits = 0;
  if (info->features & CURL_VERSION_HTTP2) bits |= 1;
  if (info->features & CURL_VERSION_HTTP3) bits |= 2;
#ifdef HAVE_POSTTRANSFER
  if (info->version_num >= 0x080a00) bits |= 4;
#endif
  return bits;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_curl_version(void) {
  pthread_once(&global_once, global_init);
  const char *v = curl_version();
  size_t n = strlen(v);
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  memcpy(b, v, n);
  return b;
}

// A box holding NULL when the thread cannot start.
MOONBIT_FFI_EXPORT engine_box *mttp_curl_engine_new(void) {
  pthread_once(&global_once, global_init);
  engine_box *b = moonbit_make_external_object(engine_box_finalize, sizeof(engine_box));
  b->e = NULL;
  engine *e = calloc(1, sizeof *e);
  e->multi = curl_multi_init();
  if (!e->multi) {
    free(e);
    return b;
  }
  curl_multi_setopt(e->multi, CURLMOPT_PIPELINING, CURLPIPE_MULTIPLEX);
  pthread_mutex_init(&e->qlock, NULL);
  e->refs = 2;  // MoonBit's box and the thread
  pthread_t thread;
  if (pthread_create(&thread, NULL, engine_main, e) != 0) {
    curl_multi_cleanup(e->multi);
    pthread_mutex_destroy(&e->qlock);
    free(e);
    return b;
  }
  pthread_detach(thread);
  b->e = e;
  return b;
}

// Asks the engine to stop: no new transfers, those in flight end as Closed,
// and the thread ends once idle. Idempotent.
MOONBIT_FFI_EXPORT void mttp_curl_engine_close(engine_box *b) {
  if (b->e) engine_close(b->e);
}

static char *dup_bytes(moonbit_bytes_t b) {
  size_t n = (size_t)Moonbit_array_length(b);
  char *s = malloc(n + 1);
  memcpy(s, b, n);
  s[n] = 0;
  return s;
}

// `version`: the CURL_HTTP_VERSION_* value. `body`: -2 for no body, -1 for a
// body of unknown length, else its length. `cainfo`: a PEM file or empty.
// `insecure`: skip certificate checks. `proxy`: the proxy URL or empty for
// none; `noproxy`: the hosts reached without it. Returns NULL on failure.
MOONBIT_FFI_EXPORT transfer_box *mttp_curl_transfer_new(
    engine_box *eb, moonbit_bytes_t url, moonbit_bytes_t method, int32_t nobody,
    int64_t body, int32_t version, moonbit_bytes_t cainfo, int32_t insecure,
    int32_t head_max, int32_t body_cap, int32_t max_age_s, moonbit_bytes_t proxy,
    moonbit_bytes_t noproxy) {
  transfer_box *box = moonbit_make_external_object(transfer_box_finalize, sizeof(transfer_box));
  box->t = NULL;
  engine *e = eb->e;
  if (!e) return box;
  // A closed engine makes no transfer; mttp_curl_engine_is_closed tells
  // MoonBit why the box is empty.
  pthread_mutex_lock(&e->qlock);
  int closed = e->shutdown;
  if (!closed) e->refs++;  // the transfer's reference
  pthread_mutex_unlock(&e->qlock);
  if (closed) return box;
  CURL *easy = curl_easy_init();
  if (!easy) {
    engine_unref(e);
    return box;
  }
  transfer *t = calloc(1, sizeof *t);
  t->e = e;
  t->easy = easy;
  if (open_notify(t) != 0) {
    curl_easy_cleanup(easy);
    free(t);
    engine_unref(e);
    return box;
  }
  pthread_mutex_init(&t->lock, NULL);
  t->refs = 1;  // MoonBit's box
  t->head_max = head_max > 0 ? (size_t)head_max : 16384;
  t->head = malloc(t->head_max);
  t->body_cap = body_cap > 0 ? (size_t)body_cap : 65536;
  t->body = malloc(t->body_cap);
  t->up_eof = body == -2;

  char *s = dup_bytes(url);
  curl_easy_setopt(easy, CURLOPT_URL, s);
  // Wait for a connection being set up to say whether it multiplexes rather
  // than open another, so that requests to an origin share one HTTP/2
  // connection. Only over TLS, where ALPN says so in the handshake: libcurl
  // 8.14 keeps a cleartext connection abandoned mid-stream undecided, and a
  // later request would wait on it for ever.
  int tls = strncmp(s, "https:", 6) == 0;
  free(s);
  // The request's shape is set explicitly rather than left to libcurl's
  // defaults, which pick the method from other options (UPLOAD means PUT,
  // POSTFIELDS POST and adds a form Content-Type, NOBODY HEAD): the method
  // is always CUSTOMREQUEST, and the body is always an upload of known or
  // unknown length, whatever the method.
  s = dup_bytes(method);
  if (nobody) {
    curl_easy_setopt(easy, CURLOPT_NOBODY, 1L);
  } else if (body >= -1) {
    curl_easy_setopt(easy, CURLOPT_UPLOAD, 1L);
    curl_easy_setopt(easy, CURLOPT_INFILESIZE_LARGE, (curl_off_t)body);
  } else if (strcmp(s, "POST") == 0 || strcmp(s, "PUT") == 0 ||
             strcmp(s, "PATCH") == 0) {
    // No body where one is expected still says so: Content-Length: 0.
    curl_easy_setopt(easy, CURLOPT_UPLOAD, 1L);
    curl_easy_setopt(easy, CURLOPT_INFILESIZE_LARGE, (curl_off_t)0);
  }
  curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, s);
  free(s);

  curl_easy_setopt(easy, CURLOPT_PRIVATE, (char *)t);
  curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, t->errbuf);
  curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, on_header);
  curl_easy_setopt(easy, CURLOPT_HEADERDATA, t);
  curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, on_body);
  curl_easy_setopt(easy, CURLOPT_WRITEDATA, t);
  curl_easy_setopt(easy, CURLOPT_READFUNCTION, on_read);
  curl_easy_setopt(easy, CURLOPT_READDATA, t);
  curl_easy_setopt(easy, CURLOPT_PREREQFUNCTION, on_prereq);
  curl_easy_setopt(easy, CURLOPT_PREREQDATA, t);
#ifdef HAVE_POSTTRANSFER
  curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, on_progress);
  curl_easy_setopt(easy, CURLOPT_XFERINFODATA, t);
  curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
#endif
  // mttp's policies stay mttp's: no redirects, decoding, cookies or
  // signals, and only the proxy the caller chose (an empty CURLOPT_PROXY
  // also keeps libcurl from reading the proxy variables itself).
  curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(easy, CURLOPT_HTTP_CONTENT_DECODING, 0L);
  curl_easy_setopt(easy, CURLOPT_HTTP_TRANSFER_DECODING, 1L);
  s = dup_bytes(proxy);
  curl_easy_setopt(easy, CURLOPT_PROXY, s);
  free(s);
  if (Moonbit_array_length(noproxy) > 0) {
    s = dup_bytes(noproxy);
    curl_easy_setopt(easy, CURLOPT_NOPROXY, s);
    free(s);
  }
  // A proxy's answer to CONNECT is not the response's head.
  curl_easy_setopt(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
  curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, (long)version);
  if (tls) curl_easy_setopt(easy, CURLOPT_PIPEWAIT, 1L);
  // libcurl's trace on stderr, for debugging the backend itself.
  if (getenv("MTTP_CURL_VERBOSE")) curl_easy_setopt(easy, CURLOPT_VERBOSE, 1L);
  if (max_age_s == 0) {
    curl_easy_setopt(easy, CURLOPT_FORBID_REUSE, 1L);
  } else if (max_age_s > 0) {
    curl_easy_setopt(easy, CURLOPT_MAXLIFETIME_CONN, (long)max_age_s);
  }
  if (Moonbit_array_length(cainfo) > 0) {
    s = dup_bytes(cainfo);
    curl_easy_setopt(easy, CURLOPT_CAINFO, s);
    curl_easy_setopt(easy, CURLOPT_PROXY_CAINFO, s);
    free(s);
  }
  if (insecure) {
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 0L);
    curl_easy_setopt(easy, CURLOPT_PROXY_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(easy, CURLOPT_PROXY_SSL_VERIFYHOST, 0L);
  }
  box->t = t;
  return box;
}

MOONBIT_FFI_EXPORT int32_t mttp_curl_engine_is_closed(engine_box *b) {
  if (!b->e) return 0;
  pthread_mutex_lock(&b->e->qlock);
  int closed = b->e->shutdown;
  pthread_mutex_unlock(&b->e->qlock);
  return closed;
}

// One request field, "Name: value", or "Name:" to suppress curl's own.
MOONBIT_FFI_EXPORT void mttp_curl_transfer_header(transfer_box *tb, moonbit_bytes_t line) {
  transfer *t = tb->t;
  char *s = dup_bytes(line);
  t->headers = curl_slist_append(t->headers, s);
  free(s);
}

// A descriptor of the transfer's notification for MoonBit's RawFd, which
// owns it.
MOONBIT_FFI_EXPORT int mttp_curl_transfer_fd(transfer_box *tb) {
  transfer *t = tb->t;
  return fcntl(t->notify_r, F_DUPFD_CLOEXEC, 0);
}

MOONBIT_FFI_EXPORT void mttp_curl_transfer_start(transfer_box *tb) {
  transfer *t = tb->t;
  curl_easy_setopt(t->easy, CURLOPT_HTTPHEADER, t->headers);
  enqueue(t->e, CMD_ADD, t);
}

MOONBIT_FFI_EXPORT int32_t mttp_curl_transfer_state(transfer_box *tb) {
  transfer *t = tb->t;
  pthread_mutex_lock(&t->lock);
  int32_t s = t->state;
  pthread_mutex_unlock(&t->lock);
  return s;
}

// 0: status, 1: CURL_HTTP_VERSION_*, 2: CURLcode, 3: the proxy's answer to
// CONNECT (0 without one).
MOONBIT_FFI_EXPORT int32_t mttp_curl_transfer_info(transfer_box *tb, int32_t which) {
  transfer *t = tb->t;
  pthread_mutex_lock(&t->lock);
  int32_t v = 0;
  switch (which) {
    case 0: v = t->status; break;
    case 1: v = t->version; break;
    case 2: v = t->result; break;
    case 3: v = t->connect_code; break;
  }
  pthread_mutex_unlock(&t->lock);
  return v;
}

// 0: the response head, 1: curl's error text.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_curl_transfer_text(transfer_box *tb, int32_t which) {
  transfer *t = tb->t;
  pthread_mutex_lock(&t->lock);
  const char *p = "";
  size_t n = 0;
  switch (which) {
    case 0: p = t->head; n = t->head_len; break;
    case 1: p = t->errbuf; n = strlen(t->errbuf); break;
  }
  if (n == 0 && which == 1 && t->result != 0) {
    p = curl_easy_strerror((CURLcode)t->result);
    n = strlen(p);
  }
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  memcpy(b, p, n);
  pthread_mutex_unlock(&t->lock);
  return b;
}

// Copies up to `max` buffered body bytes into `out`; the count. Queues an
// unpause when curl waits for room.
MOONBIT_FFI_EXPORT int32_t mttp_curl_transfer_read(transfer_box *tb, uint8_t *out, int32_t max) {
  transfer *t = tb->t;
  pthread_mutex_lock(&t->lock);
  size_t held = t->body_len - t->body_off;
  size_t k = held < (size_t)max ? held : (size_t)max;
  memcpy(out, t->body + t->body_off, k);
  t->body_off += k;
  if (t->body_off == t->body_len) {
    t->body_off = t->body_len = 0;
    t->state &= ~ST_BODY;
  }
  int unpause = t->paused_write && t->body_len == 0;
  if (unpause) t->paused_write = 0;
  pthread_mutex_unlock(&t->lock);
  if (unpause) enqueue(t->e, CMD_UNPAUSE, t);
  return (int32_t)k;
}

// Hands curl the next piece of the request body; `eof` after the last.
MOONBIT_FFI_EXPORT void mttp_curl_transfer_push(transfer_box *tb, moonbit_bytes_t data, int32_t eof) {
  transfer *t = tb->t;
  size_t n = (size_t)Moonbit_array_length(data);
  pthread_mutex_lock(&t->lock);
  if (n > 0) {
    size_t held = t->up_len - t->up_off;
    uint8_t *up = malloc(held + n);
    if (held) memcpy(up, t->up + t->up_off, held);
    memcpy(up + held, data, n);
    free(t->up);
    t->up = up;
    t->up_off = 0;
    t->up_len = held + n;
  }
  if (eof) t->up_eof = 1;
  int unpause = t->paused_read;
  t->paused_read = 0;
  t->state &= ~ST_WANTS_BODY;
  pthread_mutex_unlock(&t->lock);
  if (unpause) enqueue(t->e, CMD_UNPAUSE, t);
}

// Gives up the rest of the request body: a final response arrived first.
MOONBIT_FFI_EXPORT void mttp_curl_transfer_abandon_upload(transfer_box *tb) {
  transfer *t = tb->t;
  pthread_mutex_lock(&t->lock);
  t->up_abandoned = 1;
  t->state &= ~ST_WANTS_BODY;
  free(t->up);
  t->up = NULL;
  t->up_off = t->up_len = 0;
  pthread_mutex_unlock(&t->lock);
}

// Ends the transfer: the thread takes it out of the multi handle. Its
// memory stays until MoonBit's box lets go too. Idempotent.
MOONBIT_FFI_EXPORT void mttp_curl_transfer_release(transfer_box *b) {
  transfer *t = b->t;
  if (!t) return;
  pthread_mutex_lock(&t->lock);
  int released = t->released;
  t->released = 1;
  pthread_mutex_unlock(&t->lock);
  if (!released) enqueue(t->e, CMD_REMOVE, t);
}


// libcurl's version as 0xXXYYZZ, for the tests that differ by version.
MOONBIT_FFI_EXPORT int32_t mttp_curl_version_num(void) {
  pthread_once(&global_once, global_init);
  return (int32_t)curl_version_info(CURLVERSION_NOW)->version_num;
}
