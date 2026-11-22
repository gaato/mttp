// gaato/mttp_ng/h2: HTTP/2 framing on the system's nghttp2, without I/O.
//
// A session is an nghttp2 session that never touches a socket. MoonBit hands
// it the bytes it read (`recv`), takes the bytes to write (`send`), and
// submits requests, responses, data, resets and GOAWAY. nghttp2's callbacks
// never call into MoonBit: each appends a record to the session's event
// buffer, which MoonBit takes after a step (`events`) and decodes in
// events.mbt. So no callback runs MoonBit code, and nothing is reentrant.
//
// A stream's outgoing body waits in a queue of its own (`outq`), which the
// data provider copies from. An empty queue that is not ended defers the
// stream; `push` adds bytes and resumes it. When the provider has taken the
// queue below `low`, it records DRAINED once, which wakes the task feeding
// that body.
//
// Received data is not acknowledged by nghttp2 itself
// (no_auto_window_update): MoonBit acknowledges the connection window when
// it buffers data and a stream's window when the reader takes it, so one
// unread body holds back only its own stream.
//
// Builds against nghttp2 1.59 (Ubuntu 24.04) and later: the size-typed
// functions of 1.60 are used where they exist, and the abuse limits of later
// versions only where the header declares them.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <nghttp2/nghttp2.h>

#include "moonbit.h"

// The size-typed API (mem_recv2, data_provider2, ...) arrived in 1.60.0.
#if NGHTTP2_VERSION_NUM >= 0x013c00
#define NG_SSIZE nghttp2_ssize
#define NG_PROVIDER nghttp2_data_provider2
#define ng_mem_recv nghttp2_session_mem_recv2
#define ng_mem_send nghttp2_session_mem_send2
#define ng_submit_request nghttp2_submit_request2
#define ng_submit_response nghttp2_submit_response2
#else
#define NG_SSIZE ssize_t
#define NG_PROVIDER nghttp2_data_provider
#define ng_mem_recv nghttp2_session_mem_recv
#define ng_mem_send nghttp2_session_mem_send
#define ng_submit_request nghttp2_submit_request
#define ng_submit_response nghttp2_submit_response
#endif

// Event records: a type byte, then fields as events.mbt reads them.
#define EV_HEADERS_BEGIN 1 // stream, category
#define EV_HEADER 2        // stream, name, value
#define EV_HEADERS_END 3   // stream, category, end_stream
#define EV_DATA 4          // stream, bytes
#define EV_END_STREAM 5    // stream
#define EV_CLOSED 6        // stream, error code
#define EV_GOAWAY 7        // last stream, error code
#define EV_SETTINGS 8      // the peer's max concurrent streams
#define EV_SENT 9          // stream, end_stream: a HEADERS or DATA frame went out
#define EV_DRAINED 10      // stream: its queue fell below the low mark
#define EV_NOT_SENT 11     // stream, nghttp2 error: a frame could not go out
#define EV_TOO_LARGE 12    // stream: its header block crossed the limit
#define EV_PING_ACK 13     // nothing: the peer answered a PING

// A uint32_t setting as MoonBit's Int: "unbounded" (0xffffffff, nghttp2's
// assumption before the peer's SETTINGS) becomes INT32_MAX.
static int32_t clamp(uint32_t v) { return v > INT32_MAX ? INT32_MAX : (int32_t)v; }

typedef struct {
  uint8_t *data;
  size_t len, cap;
  int failed; // out of memory: the session is unusable
} buffer;

static int buffer_reserve(buffer *b, size_t extra) {
  if (b->failed) return -1;
  if (b->len + extra <= b->cap) return 0;
  size_t cap = b->cap ? b->cap : 1024;
  while (cap < b->len + extra) cap *= 2;
  uint8_t *data = realloc(b->data, cap);
  if (!data) {
    b->failed = 1;
    return -1;
  }
  b->data = data;
  b->cap = cap;
  return 0;
}

static void buffer_put(buffer *b, const void *data, size_t len) {
  if (len == 0 || buffer_reserve(b, len) != 0) return;
  memcpy(b->data + b->len, data, len);
  b->len += len;
}

static void put_u8(buffer *b, uint8_t v) { buffer_put(b, &v, 1); }

static void put_i32(buffer *b, int32_t v) {
  uint8_t out[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8),
                    (uint8_t)v};
  buffer_put(b, out, 4);
}

static void put_blob(buffer *b, const uint8_t *data, size_t len) {
  put_i32(b, (int32_t)len);
  buffer_put(b, data, len);
}

// A stream's outgoing body.
typedef struct outq {
  uint8_t *data;
  size_t len, off, cap;
  int ended;      // MoonBit pushed the last bytes
  int finished;   // the provider gave EOF
  int drained;    // DRAINED was recorded since the last push
  int32_t stream; // 0 until nghttp2 assigned the request its stream
  struct outq *next;
} outq;

typedef struct {
  nghttp2_session *ng;
  buffer events;
  buffer out; // bytes to write, from send
  outq *queues;
  size_t low; // a queue below this records DRAINED
  // The header block of the stream being received: its size, to bound it
  // (name and value bytes plus 32 per field, as RFC 9113, section 6.5.2
  // counts SETTINGS_MAX_HEADER_LIST_SIZE).
  int32_t header_stream;
  size_t header_bytes;
  size_t max_header_bytes;
  int fatal; // nghttp2 returned a fatal error
} session;

typedef struct {
  session *s;
} session_box;

static void queue_free_all(session *s) {
  outq *q = s->queues;
  while (q) {
    outq *next = q->next;
    free(q->data);
    free(q);
    q = next;
  }
  s->queues = NULL;
}

static void session_free(session *s) {
  if (!s) return;
  if (s->ng) nghttp2_session_del(s->ng);
  queue_free_all(s);
  free(s->events.data);
  free(s->out.data);
  free(s);
}

static void session_box_finalize(void *self) {
  session_box *b = self;
  session_free(b->s);
  b->s = NULL;
}

static outq *queue_of(session *s, int32_t stream) {
  for (outq *q = s->queues; q; q = q->next)
    if (q->stream == stream) return q;
  return NULL;
}

static void queue_remove(session *s, outq *target) {
  outq **link = &s->queues;
  while (*link) {
    if (*link == target) {
      *link = target->next;
      free(target->data);
      free(target);
      return;
    }
    link = &(*link)->next;
  }
}

// --- callbacks -------------------------------------------------------------

static int32_t category_of(const nghttp2_frame *frame) {
  return frame->hd.type == NGHTTP2_HEADERS ? (int32_t)frame->headers.cat : -1;
}

static int on_begin_headers(nghttp2_session *ng, const nghttp2_frame *frame,
                            void *user) {
  (void)ng;
  session *s = user;
  if (frame->hd.type != NGHTTP2_HEADERS) return 0;
  s->header_stream = frame->hd.stream_id;
  s->header_bytes = 0;
  put_u8(&s->events, EV_HEADERS_BEGIN);
  put_i32(&s->events, frame->hd.stream_id);
  put_i32(&s->events, category_of(frame));
  return 0;
}

static int on_header(nghttp2_session *ng, const nghttp2_frame *frame,
                     const uint8_t *name, size_t namelen, const uint8_t *value,
                     size_t valuelen, uint8_t flags, void *user) {
  (void)flags;
  session *s = user;
  int32_t stream = frame->hd.stream_id;
  if (stream == s->header_stream) {
    s->header_bytes += namelen + valuelen + 32;
    if (s->max_header_bytes > 0 && s->header_bytes > s->max_header_bytes) {
      put_u8(&s->events, EV_TOO_LARGE);
      put_i32(&s->events, stream);
      // nghttp2 resets the stream with INTERNAL_ERROR and skips the rest of
      // the block: a client reports TooLarge in Head, and a server's peer
      // sees its request reset.
      s->header_stream = -1;
      return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    }
  } else if (s->header_stream == -1) {
    return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
  }
  put_u8(&s->events, EV_HEADER);
  put_i32(&s->events, stream);
  put_blob(&s->events, name, namelen);
  put_blob(&s->events, value, valuelen);
  return 0;
}

static int on_frame_recv(nghttp2_session *ng, const nghttp2_frame *frame,
                         void *user) {
  session *s = user;
  int end = (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0;
  switch (frame->hd.type) {
  case NGHTTP2_HEADERS:
    if (s->header_stream == -1 && frame->hd.stream_id != 0) break;
    put_u8(&s->events, EV_HEADERS_END);
    put_i32(&s->events, frame->hd.stream_id);
    put_i32(&s->events, category_of(frame));
    put_i32(&s->events, end);
    break;
  case NGHTTP2_DATA:
    if (end) {
      put_u8(&s->events, EV_END_STREAM);
      put_i32(&s->events, frame->hd.stream_id);
    }
    break;
  case NGHTTP2_GOAWAY:
    put_u8(&s->events, EV_GOAWAY);
    put_i32(&s->events, frame->goaway.last_stream_id);
    put_i32(&s->events, (int32_t)frame->goaway.error_code);
    break;
  case NGHTTP2_SETTINGS:
    if (!(frame->hd.flags & NGHTTP2_FLAG_ACK)) {
      put_u8(&s->events, EV_SETTINGS);
      put_i32(&s->events,
              clamp(nghttp2_session_get_remote_settings(
                  ng, NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS)));
    }
    break;
  case NGHTTP2_PING:
    if (frame->hd.flags & NGHTTP2_FLAG_ACK) put_u8(&s->events, EV_PING_ACK);
    break;
  default:
    break;
  }
  return 0;
}

static int on_data_chunk(nghttp2_session *ng, uint8_t flags, int32_t stream,
                         const uint8_t *data, size_t len, void *user) {
  (void)ng;
  (void)flags;
  session *s = user;
  put_u8(&s->events, EV_DATA);
  put_i32(&s->events, stream);
  put_blob(&s->events, data, len);
  return 0;
}

static int on_stream_close(nghttp2_session *ng, int32_t stream,
                           uint32_t error_code, void *user) {
  (void)ng;
  session *s = user;
  outq *q = queue_of(s, stream);
  if (q) queue_remove(s, q);
  put_u8(&s->events, EV_CLOSED);
  put_i32(&s->events, stream);
  put_i32(&s->events, (int32_t)error_code);
  return 0;
}

static int on_frame_send(nghttp2_session *ng, const nghttp2_frame *frame,
                         void *user) {
  (void)ng;
  session *s = user;
  if (frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) {
    put_u8(&s->events, EV_SENT);
    put_i32(&s->events, frame->hd.stream_id);
    put_i32(&s->events, (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0);
  }
  return 0;
}

static int on_frame_not_send(nghttp2_session *ng, const nghttp2_frame *frame,
                             int lib_error, void *user) {
  (void)ng;
  session *s = user;
  if (frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) {
    put_u8(&s->events, EV_NOT_SENT);
    put_i32(&s->events, frame->hd.stream_id);
    put_i32(&s->events, lib_error);
  }
  return 0;
}

static NG_SSIZE read_body(nghttp2_session *ng, int32_t stream, uint8_t *buf,
                          size_t length, uint32_t *flags,
                          nghttp2_data_source *source, void *user) {
  (void)ng;
  session *s = user;
  outq *q = source->ptr;
  if (q->stream == 0) q->stream = stream;
  size_t avail = q->len - q->off;
  size_t n = avail < length ? avail : length;
  if (n > 0) {
    memcpy(buf, q->data + q->off, n);
    q->off += n;
    if (q->off == q->len) q->off = q->len = 0;
  }
  if (q->len - q->off < s->low && !q->drained && !q->ended) {
    q->drained = 1;
    put_u8(&s->events, EV_DRAINED);
    put_i32(&s->events, stream);
  }
  if (q->len == q->off && q->ended) {
    *flags |= NGHTTP2_DATA_FLAG_EOF;
    q->finished = 1;
    return (NG_SSIZE)n;
  }
  if (n == 0) return NGHTTP2_ERR_DEFERRED;
  return (NG_SSIZE)n;
}

// --- creating a session ----------------------------------------------------

// Settings and limits, in the order sessions.mbt passes them.
typedef struct {
  int32_t max_concurrent_streams; // advertised; 0: nghttp2's default (none)
  int32_t initial_window;         // per stream
  int32_t connection_window;
  int32_t max_frame_size;
  int32_t header_table_size;
  int32_t max_header_list;        // advertised and enforced in on_header
  int32_t low_mark;               // DRAINED below this many queued bytes
} config;

static session *session_new(int server, const int32_t *values) {
  config c = {values[0], values[1], values[2], values[3],
              values[4], values[5], values[6]};
  session *s = calloc(1, sizeof *s);
  if (!s) return NULL;
  s->low = c.low_mark > 0 ? (size_t)c.low_mark : 16384;
  s->max_header_bytes = c.max_header_list > 0 ? (size_t)c.max_header_list : 0;
  s->header_stream = 0;

  nghttp2_session_callbacks *cb;
  if (nghttp2_session_callbacks_new(&cb) != 0) {
    free(s);
    return NULL;
  }
  nghttp2_session_callbacks_set_on_begin_headers_callback(cb, on_begin_headers);
  nghttp2_session_callbacks_set_on_header_callback(cb, on_header);
  nghttp2_session_callbacks_set_on_frame_recv_callback(cb, on_frame_recv);
  nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cb, on_data_chunk);
  nghttp2_session_callbacks_set_on_stream_close_callback(cb, on_stream_close);
  nghttp2_session_callbacks_set_on_frame_send_callback(cb, on_frame_send);
  nghttp2_session_callbacks_set_on_frame_not_send_callback(cb, on_frame_not_send);

  nghttp2_option *opt;
  if (nghttp2_option_new(&opt) != 0) {
    nghttp2_session_callbacks_del(cb);
    free(s);
    return NULL;
  }
  nghttp2_option_set_no_auto_window_update(opt, 1);
  // Both ends bound what the peer can make them hold (SECURITY_CLASSES.md):
  // queued SETTINGS and PING acknowledgements, SETTINGS entries, and the
  // header compression table nghttp2 keeps for its own output.
  nghttp2_option_set_max_outbound_ack(opt, 1000);
  nghttp2_option_set_max_settings(opt, 32);
  nghttp2_option_set_max_deflate_dynamic_table_size(opt, 4096);
  if (!server) {
    // No server push: SETTINGS_ENABLE_PUSH is 0 below, and nothing is
    // reserved for it.
    nghttp2_option_set_max_reserved_remote_streams(opt, 0);
  }
#if NGHTTP2_VERSION_NUM >= 0x013900
  // Rapid Reset (CVE-2023-44487): nghttp2's own limit on resets per second,
  // since 1.57.
  nghttp2_option_set_stream_reset_rate_limit(opt, 1000, 33);
#endif
#if NGHTTP2_VERSION_NUM >= 0x013d00
  // CONTINUATION floods (CVE-2024-28182), since 1.61.
  nghttp2_option_set_max_continuations(opt, 8);
#endif
#if NGHTTP2_VERSION_NUM >= 0x014300
  // Frames that are each harmless but together a flood, since 1.67.
  nghttp2_option_set_glitch_rate_limit(opt, 1000, 33);
#endif

  int rv = server ? nghttp2_session_server_new2(&s->ng, cb, s, opt)
                  : nghttp2_session_client_new2(&s->ng, cb, s, opt);
  nghttp2_option_del(opt);
  nghttp2_session_callbacks_del(cb);
  if (rv != 0) {
    free(s);
    return NULL;
  }

  nghttp2_settings_entry iv[6];
  size_t n = 0;
  if (!server) {
    iv[n].settings_id = NGHTTP2_SETTINGS_ENABLE_PUSH;
    iv[n++].value = 0;
  }
  if (c.max_concurrent_streams > 0) {
    iv[n].settings_id = NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
    iv[n++].value = (uint32_t)c.max_concurrent_streams;
  }
  if (c.initial_window > 0) {
    iv[n].settings_id = NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE;
    iv[n++].value = (uint32_t)c.initial_window;
  }
  if (c.max_frame_size > 0) {
    iv[n].settings_id = NGHTTP2_SETTINGS_MAX_FRAME_SIZE;
    iv[n++].value = (uint32_t)c.max_frame_size;
  }
  if (c.header_table_size >= 0) {
    iv[n].settings_id = NGHTTP2_SETTINGS_HEADER_TABLE_SIZE;
    iv[n++].value = (uint32_t)c.header_table_size;
  }
  if (c.max_header_list > 0) {
    iv[n].settings_id = NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE;
    iv[n++].value = (uint32_t)c.max_header_list;
  }
  if (nghttp2_submit_settings(s->ng, NGHTTP2_FLAG_NONE, iv, n) != 0 ||
      (c.connection_window > 65535 &&
       nghttp2_session_set_local_window_size(s->ng, NGHTTP2_FLAG_NONE, 0,
                                             c.connection_window) != 0)) {
    session_free(s);
    return NULL;
  }
  return s;
}

static session_box *box(session *s) {
  session_box *b =
      moonbit_make_external_object(session_box_finalize, sizeof(session_box));
  b->s = s;
  return b;
}

MOONBIT_FFI_EXPORT session_box *mttp_ng_h2_session_new(int32_t server,
                                                       int32_t *values) {
  return box(session_new(server, values));
}

static int usable(session_box *b) {
  return b->s && b->s->ng && !b->s->fatal && !b->s->events.failed &&
         !b->s->out.failed;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_session_failed(session_box *b) {
  return !usable(b);
}

MOONBIT_FFI_EXPORT void mttp_ng_h2_session_free(session_box *b) {
  session_free(b->s);
  b->s = NULL;
}

// --- steps -----------------------------------------------------------------

// Processes `len` bytes of `data[offset..]`: 0, or an nghttp2 error code,
// after which the session is fatal and only its output (a GOAWAY) remains.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_recv(session_box *b, moonbit_bytes_t data,
                                           int32_t offset, int32_t len) {
  if (!usable(b)) return NGHTTP2_ERR_INVALID_STATE;
  session *s = b->s;
  NG_SSIZE rv = ng_mem_recv(s->ng, data + offset, (size_t)len);
  if (rv < 0) {
    s->fatal = 1;
    return (int32_t)rv;
  }
  return 0;
}

// Serializes everything nghttp2 wants to send into the output buffer and
// takes it: the bytes to write beneath, possibly empty.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h2_send(session_box *b) {
  session *s = b->s;
  if (s && s->ng) {
    for (;;) {
      const uint8_t *chunk;
      NG_SSIZE n = ng_mem_send(s->ng, &chunk);
      if (n < 0) {
        s->fatal = 1;
        break;
      }
      if (n == 0) break;
      buffer_put(&s->out, chunk, (size_t)n);
    }
  }
  size_t len = s ? s->out.len : 0;
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) memcpy(out, s->out.data, len);
  if (s) s->out.len = 0;
  return out;
}

// Takes the events recorded since the last call.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h2_events(session_box *b) {
  session *s = b->s;
  size_t len = s ? s->events.len : 0;
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) memcpy(out, s->events.data, len);
  if (s) s->events.len = 0;
  return out;
}

// 1 when nghttp2 still reads or writes; 0 once both are over (after GOAWAY
// both ways, or a fatal error).
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_want_io(session_box *b) {
  if (!b->s || !b->s->ng) return 0;
  return nghttp2_session_want_read(b->s->ng) ||
         nghttp2_session_want_write(b->s->ng);
}

// Header fields arrive as one blob: a count, then name and value blobs.
static nghttp2_nv *fields(moonbit_bytes_t blob, size_t *count) {
  const uint8_t *p = blob;
  const uint8_t *end = blob + Moonbit_array_length(blob);
#define READ_I32(v)                                                            \
  do {                                                                         \
    if (end - p < 4) goto bad;                                                 \
    v = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |                      \
        ((uint32_t)p[2] << 8) | p[3];                                          \
    p += 4;                                                                    \
  } while (0)
  uint32_t n;
  READ_I32(n);
  if (n > 100000) goto bad;
  nghttp2_nv *nva = calloc(n ? n : 1, sizeof *nva);
  if (!nva) return NULL;
  for (uint32_t i = 0; i < n; i++) {
    uint32_t len;
    READ_I32(len);
    if ((size_t)(end - p) < len) goto bad_free;
    nva[i].name = (uint8_t *)p;
    nva[i].namelen = len;
    p += len;
    READ_I32(len);
    if ((size_t)(end - p) < len) goto bad_free;
    nva[i].value = (uint8_t *)p;
    nva[i].valuelen = len;
    p += len;
    // nghttp2 copies names and values when the frame is submitted.
    nva[i].flags = NGHTTP2_NV_FLAG_NONE;
  }
  *count = n;
  return nva;
bad_free:
  free(nva);
bad:
  *count = 0;
  return NULL;
#undef READ_I32
}

static outq *queue_new(session *s, int32_t stream) {
  outq *q = calloc(1, sizeof *q);
  if (!q) return NULL;
  q->stream = stream;
  q->next = s->queues;
  s->queues = q;
  return q;
}

// Submits a request: its stream id, or a negative nghttp2 error. With
// `body`, its data comes from `push`; without, the HEADERS frame ends it.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_submit_request(session_box *b,
                                                     moonbit_bytes_t blob,
                                                     int32_t body) {
  if (!usable(b)) return NGHTTP2_ERR_INVALID_STATE;
  session *s = b->s;
  // nghttp2 would take the request and fail it only when it comes to send
  // it (NOT_SENT); after a GOAWAY either way it is refused here instead.
  if (!nghttp2_session_check_request_allowed(s->ng))
    return NGHTTP2_ERR_START_STREAM_NOT_ALLOWED;
  size_t n;
  nghttp2_nv *nva = fields(blob, &n);
  if (!nva) return NGHTTP2_ERR_INVALID_ARGUMENT;
  outq *q = NULL;
  NG_PROVIDER provider;
  if (body) {
    q = queue_new(s, 0);
    if (!q) {
      free(nva);
      return NGHTTP2_ERR_NOMEM;
    }
    provider.source.ptr = q;
    provider.read_callback = read_body;
  }
  int32_t stream = ng_submit_request(s->ng, NULL, nva, n, body ? &provider : NULL, NULL);
  free(nva);
  if (q) {
    if (stream < 0) {
      queue_remove(s, q);
    } else {
      q->stream = stream;
    }
  }
  return stream;
}

// Submits the response on `stream`: 0 or a negative nghttp2 error.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_submit_response(session_box *b,
                                                      int32_t stream,
                                                      moonbit_bytes_t blob,
                                                      int32_t body) {
  if (!usable(b)) return NGHTTP2_ERR_INVALID_STATE;
  session *s = b->s;
  size_t n;
  nghttp2_nv *nva = fields(blob, &n);
  if (!nva) return NGHTTP2_ERR_INVALID_ARGUMENT;
  outq *q = NULL;
  NG_PROVIDER provider;
  if (body) {
    q = queue_new(s, stream);
    if (!q) {
      free(nva);
      return NGHTTP2_ERR_NOMEM;
    }
    provider.source.ptr = q;
    provider.read_callback = read_body;
  }
  int rv = ng_submit_response(s->ng, stream, nva, n, body ? &provider : NULL);
  free(nva);
  if (rv != 0 && q) queue_remove(s, q);
  return rv;
}

// Queues `len` bytes of `data[offset..]` for `stream`'s body, ending it with
// `end`: 0, or -1 when the stream has no queue (closed, or no body).
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_push(session_box *b, int32_t stream,
                                           moonbit_bytes_t data, int32_t offset,
                                           int32_t len, int32_t end) {
  if (!usable(b)) return -1;
  session *s = b->s;
  outq *q = queue_of(s, stream);
  if (!q || q->ended) return -1;
  if (len > 0) {
    if (q->off > 0 && q->off == q->len) q->off = q->len = 0;
    if (q->len + (size_t)len > q->cap) {
      size_t cap = q->cap ? q->cap : 16384;
      while (cap < q->len + (size_t)len) cap *= 2;
      uint8_t *grown = realloc(q->data, cap);
      if (!grown) return -1;
      q->data = grown;
      q->cap = cap;
    }
    memcpy(q->data + q->len, data + offset, (size_t)len);
    q->len += (size_t)len;
  }
  if (end) q->ended = 1;
  q->drained = 0;
  nghttp2_session_resume_data(s->ng, stream);
  return 0;
}

// How many bytes wait in `stream`'s queue, or -1 without one.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_queued(session_box *b, int32_t stream) {
  if (!b->s) return -1;
  outq *q = queue_of(b->s, stream);
  return q ? (int32_t)(q->len - q->off) : -1;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_reset(session_box *b, int32_t stream,
                                            int32_t code) {
  if (!usable(b)) return NGHTTP2_ERR_INVALID_STATE;
  return nghttp2_submit_rst_stream(b->s->ng, NGHTTP2_FLAG_NONE, stream,
                                   (uint32_t)code);
}

// Acknowledges `len` bytes: of the connection window with `stream` 0, else
// of that stream's.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_consume(session_box *b, int32_t stream,
                                              int32_t len) {
  if (!usable(b) || len <= 0) return 0;
  return stream == 0
             ? nghttp2_session_consume_connection(b->s->ng, (size_t)len)
             : nghttp2_session_consume_stream(b->s->ng, stream, (size_t)len);
}

// GOAWAY with `code`, naming the last stream this end processed.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_goaway(session_box *b, int32_t code) {
  if (!b->s || !b->s->ng) return NGHTTP2_ERR_INVALID_STATE;
  nghttp2_session *ng = b->s->ng;
  return nghttp2_submit_goaway(ng, NGHTTP2_FLAG_NONE,
                               nghttp2_session_get_last_proc_stream_id(ng),
                               (uint32_t)code, NULL, 0);
}

// A server's first GOAWAY of a graceful shutdown (RFC 9113, section 6.8):
// the highest stream identifier, so streams in flight still start.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_shutdown_notice(session_box *b) {
  if (!usable(b)) return NGHTTP2_ERR_INVALID_STATE;
  return nghttp2_submit_shutdown_notice(b->s->ng);
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_ping(session_box *b) {
  if (!usable(b)) return NGHTTP2_ERR_INVALID_STATE;
  return nghttp2_submit_ping(b->s->ng, NGHTTP2_FLAG_NONE, NULL);
}

// The peer's SETTINGS_MAX_CONCURRENT_STREAMS.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_remote_max_streams(session_box *b) {
  if (!b->s || !b->s->ng) return 0;
  return clamp(nghttp2_session_get_remote_settings(
      b->s->ng, NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS));
}

// Whether the peer may still open streams to this end (a server) or this
// end may still open streams (a client): nghttp2 refuses new ones after a
// GOAWAY either way.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_can_open(session_box *b) {
  if (!usable(b)) return 0;
  return nghttp2_session_check_request_allowed(b->s->ng);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h2_strerror(int32_t code) {
  const char *text = nghttp2_strerror(code);
  int32_t n = (int32_t)strlen(text);
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  memcpy(out, text, n);
  return out;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h2_version(void) {
  return nghttp2_version(0)->version_num;
}
