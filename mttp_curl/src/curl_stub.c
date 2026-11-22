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
// transfer, under the transfer's mutex, and then bumps the transfer's eventfd.
// The MoonBit side holds a dup of that eventfd in a core/async RawFd and
// waits on it; reading it resets the count, and it then reads a snapshot of
// the transfer's state. The dup lets MoonBit close its end whenever it is
// unwound without racing the thread, which keeps writing to its own end
// until it frees the transfer, so a reused descriptor number is never hit.
//
// A transfer is freed by the thread when it handles the transfer's remove
// command, which MoonBit queues exactly once and never touches the transfer
// afterwards. An engine is freed by its thread once shutdown was asked for
// and every transfer has been removed.

#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include "moonbit.h"

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
  cmd *qhead, *qtail;
  int shutdown;   // under qlock
  int live;       // transfers not yet removed, under qlock
} engine;

struct transfer {
  engine *e;
  CURL *easy;
  struct curl_slist *headers;
  int efd;        // the thread's end; MoonBit waits on a dup
  int added;      // in the multi handle; the thread's own field
  pthread_mutex_t lock;
  // Under lock from here on.
  int state;
  int paused_write;
  int paused_read;
  int32_t status;
  int32_t version;
  int32_t num_connects;
  int32_t result;
  char errbuf[CURL_ERROR_SIZE];
  char primary_ip[64];
  int32_t primary_port;
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

static void notify(transfer *t) {
  uint64_t one = 1;
  ssize_t r;
  do {
    r = write(t->efd, &one, sizeof one);
  } while (r < 0 && errno == EINTR);
}

static void enqueue(engine *e, cmd_kind kind, transfer *t) {
  cmd *c = malloc(sizeof *c);
  c->kind = kind;
  c->t = t;
  c->next = NULL;
  pthread_mutex_lock(&e->qlock);
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
      long v = 0, c = 0, port = 0;
      char *ip = NULL;
      curl_easy_getinfo(t->easy, CURLINFO_HTTP_VERSION, &v);
      curl_easy_getinfo(t->easy, CURLINFO_NUM_CONNECTS, &c);
      t->version = (int32_t)v;
      t->num_connects = (int32_t)c;
      if (curl_easy_getinfo(t->easy, CURLINFO_PRIMARY_IP, &ip) == CURLE_OK && ip) {
        strncpy(t->primary_ip, ip, sizeof t->primary_ip - 1);
      }
      if (curl_easy_getinfo(t->easy, CURLINFO_PRIMARY_PORT, &port) == CURLE_OK) {
        t->primary_port = (int32_t)port;
      }
      t->state |= ST_HEAD;
      finished = 1;
    }
  }
  pthread_mutex_unlock(&t->lock);
  if (finished) notify(t);
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
  (void)local_ip;
  (void)local_port;
  transfer *t = arg;
  pthread_mutex_lock(&t->lock);
  t->state |= ST_PREREQ;
  if (remote_ip) strncpy(t->primary_ip, remote_ip, sizeof t->primary_ip - 1);
  t->primary_port = remote_port;
  pthread_mutex_unlock(&t->lock);
  notify(t);
  return CURL_PREREQFUNC_OK;
}

// Called by curl on the thread while a transfer runs: notes the moment the
// whole request has been sent, so that a failure or deadline before the
// response head says Head rather than Write.
static int on_progress(void *arg, curl_off_t dltotal, curl_off_t dlnow,
                       curl_off_t ultotal, curl_off_t ulnow) {
  (void)dltotal;
  (void)dlnow;
  (void)ultotal;
  (void)ulnow;
  transfer *t = arg;
  pthread_mutex_lock(&t->lock);
  int known = t->state & ST_SENT;
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

// --------------------------------------------------------------- the thread

static void free_transfer(transfer *t) {
  engine *e = t->e;
  if (t->added) curl_multi_remove_handle(e->multi, t->easy);
  curl_easy_cleanup(t->easy);
  curl_slist_free_all(t->headers);
  close(t->efd);
  free(t->head);
  free(t->body);
  free(t->up);
  pthread_mutex_destroy(&t->lock);
  free(t);
  pthread_mutex_lock(&e->qlock);
  e->live--;
  pthread_mutex_unlock(&e->qlock);
}

static void finish(transfer *t, int32_t result, int closed) {
  curl_off_t sent_at = 0;
  curl_easy_getinfo(t->easy, CURLINFO_POSTTRANSFER_TIME_T, &sent_at);
  pthread_mutex_lock(&t->lock);
  t->state |= ST_DONE;
  if (closed) t->state |= ST_CLOSED;
  if (sent_at > 0) t->state |= ST_SENT;
  t->result = result;
  pthread_mutex_unlock(&t->lock);
  if (t->added) {
    curl_multi_remove_handle(t->e->multi, t->easy);
    t->added = 0;
  }
  notify(t);
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
            t->added = 1;
          } else {
            finish(t, CURLE_FAILED_INIT, 0);
          }
          break;
        case CMD_UNPAUSE:
          if (t->added) curl_easy_pause(t->easy, CURLPAUSE_CONT);
          break;
        case CMD_REMOVE:
          free_transfer(t);
          break;
        case CMD_SHUTDOWN:
          break;
      }
      free(c);
      c = next;
    }
    if (shutting) {
      // End every transfer still in the multi handle; their remove commands
      // follow from MoonBit, and the thread stays until they have.
      CURL **handles = curl_multi_get_handles(e->multi);
      for (CURL **h = handles; h && *h; h++) {
        transfer *t = NULL;
        curl_easy_getinfo(*h, CURLINFO_PRIVATE, (char **)&t);
        if (t) finish(t, CURLE_ABORTED_BY_CALLBACK, 1);
      }
      curl_free(handles);
      pthread_mutex_lock(&e->qlock);
      int done = e->live == 0 && e->qhead == NULL;
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
  curl_multi_cleanup(e->multi);
  pthread_mutex_destroy(&e->qlock);
  free(e);
  return NULL;
}

// ------------------------------------------------------- the MoonBit side

// Bit 1: HTTP/2, bit 2: HTTP/3.
MOONBIT_FFI_EXPORT int32_t mttp_curl_features(void) {
  pthread_once(&global_once, global_init);
  curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
  int32_t bits = 0;
  if (info->features & CURL_VERSION_HTTP2) bits |= 1;
  if (info->features & CURL_VERSION_HTTP3) bits |= 2;
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

// NULL when the thread cannot start.
MOONBIT_FFI_EXPORT engine *mttp_curl_engine_new(void) {
  pthread_once(&global_once, global_init);
  engine *e = calloc(1, sizeof *e);
  e->multi = curl_multi_init();
  if (!e->multi) {
    free(e);
    return NULL;
  }
  curl_multi_setopt(e->multi, CURLMOPT_PIPELINING, CURLPIPE_MULTIPLEX);
  pthread_mutex_init(&e->qlock, NULL);
  pthread_t thread;
  if (pthread_create(&thread, NULL, engine_main, e) != 0) {
    curl_multi_cleanup(e->multi);
    pthread_mutex_destroy(&e->qlock);
    free(e);
    return NULL;
  }
  pthread_detach(thread);
  return e;
}

// After this call MoonBit adds no more transfers to `e`; the thread frees it
// once the transfers already made are removed.
MOONBIT_FFI_EXPORT void mttp_curl_engine_close(engine *e) {
  pthread_mutex_lock(&e->qlock);
  e->shutdown = 1;
  pthread_mutex_unlock(&e->qlock);
  enqueue(e, CMD_SHUTDOWN, NULL);
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
// `insecure`: skip certificate checks. Returns NULL on failure.
MOONBIT_FFI_EXPORT transfer *mttp_curl_transfer_new(
    engine *e, moonbit_bytes_t url, moonbit_bytes_t method, int32_t nobody,
    int64_t body, int32_t version, moonbit_bytes_t cainfo, int32_t insecure,
    int32_t head_max, int32_t body_cap, int32_t max_age_s) {
  CURL *easy = curl_easy_init();
  if (!easy) return NULL;
  transfer *t = calloc(1, sizeof *t);
  t->e = e;
  t->easy = easy;
  t->efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (t->efd < 0) {
    curl_easy_cleanup(easy);
    free(t);
    return NULL;
  }
  pthread_mutex_init(&t->lock, NULL);
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
  s = dup_bytes(method);
  if (nobody) {
    curl_easy_setopt(easy, CURLOPT_NOBODY, 1L);
  } else if (body >= -1) {
    curl_easy_setopt(easy, CURLOPT_UPLOAD, 1L);
    curl_easy_setopt(easy, CURLOPT_INFILESIZE_LARGE, (curl_off_t)body);
  } else if (strcmp(s, "POST") == 0 || strcmp(s, "PUT") == 0 ||
             strcmp(s, "PATCH") == 0) {
    // An empty body still says so: Content-Length: 0.
    curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)0);
    curl_easy_setopt(easy, CURLOPT_COPYPOSTFIELDS, "");
  }
  if (!nobody && strcmp(s, "GET") != 0) {
    curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, s);
  }
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
  curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, on_progress);
  curl_easy_setopt(easy, CURLOPT_XFERINFODATA, t);
  curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
  // mttp's policies stay mttp's: no redirects, decoding, cookies, proxies
  // (curl reads the proxy variables unless told otherwise) or signals.
  curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(easy, CURLOPT_HTTP_CONTENT_DECODING, 0L);
  curl_easy_setopt(easy, CURLOPT_HTTP_TRANSFER_DECODING, 1L);
  curl_easy_setopt(easy, CURLOPT_PROXY, "");
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
    free(s);
  }
  if (insecure) {
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 0L);
  }
  pthread_mutex_lock(&e->qlock);
  e->live++;
  pthread_mutex_unlock(&e->qlock);
  return t;
}

// One request field, "Name: value", or "Name:" to suppress curl's own.
MOONBIT_FFI_EXPORT void mttp_curl_transfer_header(transfer *t, moonbit_bytes_t line) {
  char *s = dup_bytes(line);
  t->headers = curl_slist_append(t->headers, s);
  free(s);
}

// A descriptor of the transfer's eventfd for MoonBit's RawFd, which owns it.
MOONBIT_FFI_EXPORT int mttp_curl_transfer_fd(transfer *t) {
  return fcntl(t->efd, F_DUPFD_CLOEXEC, 0);
}

MOONBIT_FFI_EXPORT void mttp_curl_transfer_start(transfer *t) {
  curl_easy_setopt(t->easy, CURLOPT_HTTPHEADER, t->headers);
  enqueue(t->e, CMD_ADD, t);
}

MOONBIT_FFI_EXPORT int32_t mttp_curl_transfer_state(transfer *t) {
  pthread_mutex_lock(&t->lock);
  int32_t s = t->state;
  pthread_mutex_unlock(&t->lock);
  return s;
}

// 0: status, 1: CURL_HTTP_VERSION_*, 2: CURLcode, 3: connections opened,
// 4: the peer's port.
MOONBIT_FFI_EXPORT int32_t mttp_curl_transfer_info(transfer *t, int32_t which) {
  pthread_mutex_lock(&t->lock);
  int32_t v = 0;
  switch (which) {
    case 0: v = t->status; break;
    case 1: v = t->version; break;
    case 2: v = t->result; break;
    case 3: v = t->num_connects; break;
    case 4: v = t->primary_port; break;
  }
  pthread_mutex_unlock(&t->lock);
  return v;
}

// 0: the response head, 1: curl's error text, 2: the peer's address.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_curl_transfer_text(transfer *t, int32_t which) {
  pthread_mutex_lock(&t->lock);
  const char *p = "";
  size_t n = 0;
  switch (which) {
    case 0: p = t->head; n = t->head_len; break;
    case 1: p = t->errbuf; n = strlen(t->errbuf); break;
    case 2: p = t->primary_ip; n = strlen(t->primary_ip); break;
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
MOONBIT_FFI_EXPORT int32_t mttp_curl_transfer_read(transfer *t, uint8_t *out, int32_t max) {
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
MOONBIT_FFI_EXPORT void mttp_curl_transfer_push(transfer *t, moonbit_bytes_t data, int32_t eof) {
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

// Ends the transfer and frees it, on the thread. MoonBit calls it once and
// never uses `t` afterwards.
MOONBIT_FFI_EXPORT void mttp_curl_transfer_release(transfer *t) {
  enqueue(t->e, CMD_REMOVE, t);
}

MOONBIT_FFI_EXPORT int32_t mttp_curl_is_null(void *p) { return p == NULL; }
