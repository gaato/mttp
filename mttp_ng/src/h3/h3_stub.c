// gaato/mttp_ng/h3: QUIC and HTTP/3 on the system's ngtcp2 (with its OpenSSL
// crypto library, ngtcp2_crypto_ossl, OpenSSL 3.5 or later) and nghttp3,
// without I/O.
//
// A connection takes the datagrams MoonBit received (`read`) and gives the
// datagrams to send (`write`), and says when its timers next expire
// (`expiry_ms`, then `on_expiry`). QUIC's streams carry HTTP/3: nghttp3 reads
// what ngtcp2 delivers and writes through ngtcp2's packets, all inside a
// step, so the write loop of RFC 9114 over RFC 9000 stays here in C.
//
// As in h2_stub.c, callbacks never call into MoonBit: they append records to
// the connection's event buffer, which MoonBit takes after a step and decodes
// in events.mbt.
//
// A stream's outgoing body is a list of chunks. nghttp3 keeps pointers into
// what it sent until the peer acknowledges it, so a chunk is freed only once
// acknowledged, and never moved.
//
// Received body bytes are acknowledged to the peer's flow control only when
// MoonBit says so (`consume`), as h2 does; nghttp3's own framing bytes are
// acknowledged at once.
//
// Time is the monotonic clock's, read here: ngtcp2 wants nanoseconds that
// never go back.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <ngtcp2/ngtcp2.h>
#include <ngtcp2/ngtcp2_crypto.h>
#include <ngtcp2/ngtcp2_crypto_ossl.h>
#include <nghttp3/nghttp3.h>

#include "moonbit.h"

// Event records, as events.mbt reads them; 1 to 13 as h2_stub.c has them.
#define EV_HEADERS_BEGIN 1
#define EV_HEADER 2
#define EV_HEADERS_END 3 // stream, fin
#define EV_DATA 4
#define EV_END_STREAM 5
#define EV_CLOSED 6 // stream, error code
#define EV_GOAWAY 7 // id
#define EV_SENT 9   // stream, fin: its data went into a packet
#define EV_DRAINED 10
#define EV_TOO_LARGE 12
#define EV_HANDSHAKE 14 // the handshake completed
#define EV_CLOSE 15     // the connection closed: error code, whether by the peer
#define EV_EARLY 16     // stream: data of it arrived in 0-RTT (a server's)
#define EV_EARLY_REJECTED 17 // the server rejected this client's early data
#define EV_TICKET 18    // a session ticket arrived: `resumption` has it

#define MAX_DATAGRAM 1452
// The tickets a server's internal session cache keeps for single use.
#define SESSION_CACHE 4096
// The length of the connection IDs a server issues, so that a short header
// packet's DCID can be read before its connection is known.
#define SERVER_CIDLEN 17
// How long a Retry token is good for.
#define RETRY_TOKEN_TIMEOUT (10 * NGTCP2_SECONDS)
#define DATAGRAMS_PER_WRITE 64
#define ERROR_CAPACITY 512

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * NGTCP2_SECONDS + (uint64_t)ts.tv_nsec;
}

// --- buffers ---------------------------------------------------------------

typedef struct {
  uint8_t *data;
  size_t len, cap;
  int failed;
} buffer;

static int buffer_reserve(buffer *b, size_t extra) {
  if (b->failed) return -1;
  if (b->len + extra <= b->cap) return 0;
  size_t cap = b->cap ? b->cap : 2048;
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

static void put_i64(buffer *b, int64_t v) {
  uint8_t out[8];
  for (int i = 0; i < 8; i++) out[i] = (uint8_t)(v >> (56 - 8 * i));
  buffer_put(b, out, 8);
}

static void put_blob(buffer *b, const uint8_t *data, size_t len) {
  put_i64(b, (int64_t)len);
  buffer_put(b, data, len);
}

static moonbit_bytes_t take_buffer(buffer *b) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)b->len, 0);
  if (b->len > 0) memcpy(out, b->data, b->len);
  b->len = 0;
  return out;
}

static moonbit_bytes_t to_bytes(const char *text) {
  int32_t n = (int32_t)strlen(text);
  moonbit_bytes_t b = moonbit_make_bytes(n, 0);
  memcpy(b, text, n);
  return b;
}

// --- TLS contexts ----------------------------------------------------------

typedef struct {
  SSL_CTX *ctx;
  int early; // a server's: it issues tickets and accepts early data
  char error[ERROR_CAPACITY];
} context;

// Defined with the connections, which they read.
static int gen_ticket_cb(SSL *ssl, void *arg);
static SSL_TICKET_RETURN decrypt_ticket_cb(SSL *ssl, SSL_SESSION *session,
                                           const unsigned char *keyname,
                                           size_t keynamelen,
                                           SSL_TICKET_STATUS status, void *arg);
static int new_session_cb(SSL *ssl, SSL_SESSION *session);

typedef struct {
  context *c;
} context_box;

static void context_box_finalize(void *self) {
  context_box *b = self;
  if (b->c) {
    if (b->c->ctx) SSL_CTX_free(b->c->ctx);
    free(b->c);
  }
  b->c = NULL;
}

static void record_error(char *out, const char *fallback) {
  unsigned long code = ERR_peek_last_error();
  if (code != 0) {
    ERR_error_string_n(code, out, ERROR_CAPACITY);
  } else {
    snprintf(out, ERROR_CAPACITY, "%s", fallback);
  }
  ERR_clear_error();
}

static context_box *box_context(context *c) {
  context_box *b =
      moonbit_make_external_object(context_box_finalize, sizeof(context_box));
  b->c = c;
  return b;
}

static void context_fail(context *c, const char *fallback) {
  record_error(c->error, fallback);
  if (c->ctx) SSL_CTX_free(c->ctx);
  c->ctx = NULL;
}

static int initialised = 0;

// A server's keys (`ServerKeys`, one per listener): 32 bytes for stateless
// reset tokens, then 32 for Retry tokens. They are a listener's, not the
// process's: a listener that does not route another's connections would
// answer a packet for one of them with the reset token that connection's
// client accepts, an oracle that ends any connection whose ID it learns
// (RFC 9000, section 21.11; Codex's review of #59). A listener that
// restarts cannot reset its old connections or take its old tokens, which
// only costs their clients a timeout or a new Retry.
#define KEY_BYTES 32
#define SERVER_KEYS_BYTES (2 * KEY_BYTES)

static int ensure_init(void) {
  if (initialised) return 0;
  if (ngtcp2_crypto_ossl_init() != 0) return -1;
  initialised = 1;
  return 0;
}

static context *context_new(int server) {
  context *c = calloc(1, sizeof *c);
  if (!c) return NULL;
  ERR_clear_error();
  if (ensure_init() != 0) {
    snprintf(c->error, ERROR_CAPACITY, "ngtcp2_crypto_ossl_init failed");
    return c;
  }
  c->ctx = SSL_CTX_new(server ? TLS_server_method() : TLS_client_method());
  if (!c->ctx) {
    record_error(c->error, "SSL_CTX_new failed");
    return c;
  }
  // QUIC is TLS 1.3 only (RFC 9001, section 4.2).
  SSL_CTX_set_min_proto_version(c->ctx, TLS1_3_VERSION);
  SSL_CTX_set_max_proto_version(c->ctx, TLS1_3_VERSION);
  return c;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_context_failed(context_box *b) {
  return !b->c || !b->c->ctx;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_context_error(context_box *b) {
  return to_bytes(b->c ? b->c->error : "out of memory");
}

// trust: 0 the system's roots, 1 none checked, 2 the PEM file `path` only.
MOONBIT_FFI_EXPORT context_box *mttp_ng_h3_client_context(int32_t trust,
                                                          moonbit_bytes_t path) {
  context *c = context_new(0);
  if (!c || !c->ctx) return box_context(c);
  // A ticket the server sends goes to its connection (`new_session_cb`),
  // which keeps it for `resumption`; OpenSSL keeps none itself.
  SSL_CTX_set_session_cache_mode(c->ctx, SSL_SESS_CACHE_CLIENT |
                                             SSL_SESS_CACHE_NO_INTERNAL);
  SSL_CTX_sess_set_new_cb(c->ctx, new_session_cb);
  switch (trust) {
  case 0:
    SSL_CTX_set_verify(c->ctx, SSL_VERIFY_PEER, NULL);
    if (SSL_CTX_set_default_verify_paths(c->ctx) != 1) {
      context_fail(c, "cannot load the system's certificate roots");
    }
    break;
  case 1:
    SSL_CTX_set_verify(c->ctx, SSL_VERIFY_NONE, NULL);
    break;
  default: {
    SSL_CTX_set_verify(c->ctx, SSL_VERIFY_PEER, NULL);
    int32_t n = Moonbit_array_length(path);
    char *file = malloc((size_t)n + 1);
    if (!file) {
      context_fail(c, "out of memory");
      break;
    }
    memcpy(file, path, n);
    file[n] = 0;
    int ok = SSL_CTX_load_verify_file(c->ctx, file);
    free(file);
    if (ok != 1) context_fail(c, "cannot load the PEM file of certificate roots");
  }
  }
  return box_context(c);
}

static const unsigned char h3_alpn[] = {2, 'h', '3'};

static int select_h3(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                     const unsigned char *in, unsigned int inlen, void *arg) {
  (void)ssl;
  (void)arg;
  unsigned char *chosen = NULL;
  if (SSL_select_next_proto(&chosen, outlen, h3_alpn, sizeof h3_alpn, in,
                            inlen) != OPENSSL_NPN_NEGOTIATED) {
    // A QUIC client that does not speak h3 is refused (RFC 9001, 8.1).
    return SSL_TLSEXT_ERR_ALERT_FATAL;
  }
  *out = chosen;
  return SSL_TLSEXT_ERR_OK;
}

MOONBIT_FFI_EXPORT context_box *mttp_ng_h3_server_context(int32_t early,
                                                          moonbit_bytes_t chain,
                                                          moonbit_bytes_t key) {
  context *c = context_new(1);
  if (!c || !c->ctx) return box_context(c);
  BIO *bio = BIO_new_mem_buf(chain, Moonbit_array_length(chain));
  X509 *leaf = bio ? PEM_read_bio_X509(bio, NULL, NULL, NULL) : NULL;
  if (!leaf || SSL_CTX_use_certificate(c->ctx, leaf) != 1) {
    if (leaf) X509_free(leaf);
    if (bio) BIO_free(bio);
    context_fail(c, "cannot read the certificate");
    return box_context(c);
  }
  X509_free(leaf);
  for (;;) {
    X509 *extra = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    if (!extra) break;
    if (SSL_CTX_add1_chain_cert(c->ctx, extra) != 1) {
      X509_free(extra);
      BIO_free(bio);
      context_fail(c, "cannot add a certificate of the chain");
      return box_context(c);
    }
    X509_free(extra);
  }
  BIO_free(bio);
  ERR_clear_error();
  bio = BIO_new_mem_buf(key, Moonbit_array_length(key));
  EVP_PKEY *pkey = bio ? PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL) : NULL;
  if (bio) BIO_free(bio);
  if (!pkey || SSL_CTX_use_PrivateKey(c->ctx, pkey) != 1) {
    if (pkey) EVP_PKEY_free(pkey);
    context_fail(c, "cannot read the private key");
    return box_context(c);
  }
  EVP_PKEY_free(pkey);
  if (SSL_CTX_check_private_key(c->ctx) != 1) {
    context_fail(c, "the private key does not match the certificate");
    return box_context(c);
  }
  SSL_CTX_set_alpn_select_cb(c->ctx, select_h3, NULL);
  if (!early) {
    // No session tickets and so no 0-RTT: the server never sees early data.
    SSL_CTX_set_num_tickets(c->ctx, 0);
    SSL_CTX_set_options(c->ctx, SSL_OP_NO_TICKET);
    SSL_CTX_set_max_early_data(c->ctx, 0);
    return box_context(c);
  }
  // One ticket per connection, good for early data. A nonzero maximum makes
  // OpenSSL keep each ticket in its internal session cache and take it once
  // (SSL_read_early_data(3), REPLAY PROTECTION): a second use of a ticket
  // gets a full handshake and its early data is dropped, within this
  // context. QUIC asks for the maximum to be 0xffffffff (RFC 9001, section
  // 4.6.1). The cache holds at most SESSION_CACHE tickets; an evicted one
  // resumes nothing.
  c->early = 1;
  SSL_CTX_set_num_tickets(c->ctx, 1);
  SSL_CTX_set_max_early_data(c->ctx, UINT32_MAX);
  static const unsigned char sid[] = "gaato/mttp_ng h3";
  SSL_CTX_set_session_id_context(c->ctx, sid, sizeof sid - 1);
  SSL_CTX_sess_set_cache_size(c->ctx, SESSION_CACHE);
  SSL_CTX_set_session_ticket_cb(c->ctx, gen_ticket_cb, decrypt_ticket_cb, NULL);
  return box_context(c);
}

// --- body queues -----------------------------------------------------------

typedef struct chunk {
  uint8_t *data;
  size_t len;
  size_t sent;  // handed to nghttp3
  size_t acked; // acknowledged by the peer
  struct chunk *next;
} chunk;

// The bytes of a header section a stream is receiving. nghttp3 hands over
// fields as it decodes them, so sections of several streams can be in
// progress at once, and the bound (which nghttp3 leaves to the
// application, `max_field_section_size`) is counted per stream.
typedef struct header_count {
  int64_t stream;
  size_t bytes;
  int over; // over the bound: the rest of the section is dropped
  struct header_count *next;
} header_count;

static header_count *header_count_of(header_count *list, int64_t stream) {
  for (; list; list = list->next)
    if (list->stream == stream) return list;
  return NULL;
}

static void header_count_remove(header_count **list, int64_t stream) {
  while (*list) {
    if ((*list)->stream == stream) {
      header_count *gone = *list;
      *list = gone->next;
      free(gone);
      return;
    }
    list = &(*list)->next;
  }
}

typedef struct outq {
  int64_t stream;
  chunk *head, *tail;
  size_t queued; // bytes not yet handed to nghttp3
  int ended;
  int drained;
  // The trailer section that ends the body (a copy of its field blob), or
  // NULL: submitted when the body reaches its end, which then leaves the
  // stream open for it (RFC 9114, section 4.1).
  uint8_t *trailers;
  size_t trailers_len;
  struct outq *next;
} outq;

static void outq_free(outq *q) {
  chunk *c = q->head;
  while (c) {
    chunk *next = c->next;
    free(c->data);
    free(c);
    c = next;
  }
  free(q->trailers);
  free(q);
}

// --- connections -----------------------------------------------------------

typedef struct {
  int server;
  ngtcp2_conn *conn;
  nghttp3_conn *h3;
  SSL *ssl;
  ngtcp2_crypto_ossl_ctx *ossl;
  ngtcp2_crypto_conn_ref ref;
  struct sockaddr_storage local, remote;
  ngtcp2_path path;
  buffer events;
  // Datagrams to send, each after its length in two bytes and its
  // destination (`put_datagram`).
  buffer out;
  // The CONNECTION_CLOSE this end sent, sent again in the closing period.
  uint8_t *close_pkt;
  size_t close_len;
  int by_peer; // the peer closed the connection (its draining period)
  outq *queues;
  ngtcp2_ccerr ccerr;
  int closed;   // nothing more to read or write
  int handshake;
  size_t low;
  size_t max_header_bytes;
  // The key of this end's stateless reset tokens: its listener's for a
  // server, a random one for a client (no reset is ever sent for it).
  uint8_t reset_key[KEY_BYTES];
  // The settings it was made with, which a server stamps into its tickets
  // and requires of a ticket for its early data.
  int64_t values[6];
  // A client's: it sent early data (`early`), and the server's answer.
  int early;
  int early_rejected;
  // A client's latest ticket (DER) and the server's transport parameters
  // that go with it, for `resumption`.
  uint8_t *ticket;
  size_t ticket_len;
  uint8_t tp[256];
  size_t tp_len;
  struct header_count *headers; // header sections being received
  uint64_t max_streams_bidi;
  char error[ERROR_CAPACITY];
} qconn;

typedef struct {
  qconn *q;
} qconn_box;

static void qconn_free(qconn *q) {
  if (!q) return;
  // ngtcp2_crypto_ossl asks for the SSL's app data to be cleared before
  // SSL_free: SSL_free releases the crypto data OpenSSL still holds through
  // a callback that reaches the ngtcp2_conn through it, which by then is
  // freed. Debug builds of ngtcp2 (Homebrew's) abort there on an assertion;
  // release builds read freed memory.
  if (q->ssl) SSL_set_app_data(q->ssl, NULL);
  // QUIC ends a connection with CONNECTION_CLOSE, never a TLS shutdown;
  // OpenSSL takes an SSL freed without one for a bad session and drops it
  // from the session cache, where a server's early data needs its ticket to
  // be (replay protection takes each ticket from there once). A completed
  // handshake's session is good.
  if (q->ssl && q->handshake)
    SSL_set_shutdown(q->ssl, SSL_SENT_SHUTDOWN | SSL_RECEIVED_SHUTDOWN);
  if (q->h3) nghttp3_conn_del(q->h3);
  if (q->conn) ngtcp2_conn_del(q->conn);
  q->conn = NULL;
  if (q->ossl) ngtcp2_crypto_ossl_ctx_del(q->ossl);
  if (q->ssl) SSL_free(q->ssl);
  while (q->headers) header_count_remove(&q->headers, q->headers->stream);
  outq *o = q->queues;
  while (o) {
    outq *next = o->next;
    outq_free(o);
    o = next;
  }
  free(q->events.data);
  free(q->out.data);
  free(q->close_pkt);
  free(q->ticket);
  free(q);
}

static void qconn_box_finalize(void *self) {
  qconn_box *b = self;
  qconn_free(b->q);
  b->q = NULL;
}

static outq *queue_of(qconn *q, int64_t stream) {
  for (outq *o = q->queues; o; o = o->next)
    if (o->stream == stream) return o;
  return NULL;
}

static void queue_remove(qconn *q, int64_t stream) {
  outq **link = &q->queues;
  while (*link) {
    if ((*link)->stream == stream) {
      outq *gone = *link;
      *link = gone->next;
      outq_free(gone);
      return;
    }
    link = &(*link)->next;
  }
}

static ngtcp2_conn *get_conn(ngtcp2_crypto_conn_ref *ref) {
  return ((qconn *)ref->user_data)->conn;
}

static int parse_addr(const char *text, struct sockaddr_storage *out) {
  memset(out, 0, sizeof *out);
  char host[128];
  const char *colon = strrchr(text, ':');
  if (!colon) return -1;
  size_t hostlen = (size_t)(colon - text);
  if (hostlen >= sizeof host) return -1;
  memcpy(host, text, hostlen);
  host[hostlen] = 0;
  int port = atoi(colon + 1);
  if (host[0] == '[') {
    size_t n = strlen(host);
    if (n < 2 || host[n - 1] != ']') return -1;
    host[n - 1] = 0;
    struct sockaddr_in6 *a = (struct sockaddr_in6 *)out;
    a->sin6_family = AF_INET6;
    a->sin6_port = htons((uint16_t)port);
    return inet_pton(AF_INET6, host + 1, &a->sin6_addr) == 1 ? 0 : -1;
  }
  struct sockaddr_in *a = (struct sockaddr_in *)out;
  a->sin_family = AF_INET;
  a->sin_port = htons((uint16_t)port);
  return inet_pton(AF_INET, host, &a->sin_addr) == 1 ? 0 : -1;
}

static socklen_t addr_len(const struct sockaddr_storage *a) {
  return a->ss_family == AF_INET6 ? sizeof(struct sockaddr_in6)
                                  : sizeof(struct sockaddr_in);
}

// `addr` as `parse_addr` reads it, into `out` (at least 64 bytes); its
// length, 0 for a family other than IPv4 and IPv6.
static size_t format_addr(const ngtcp2_addr *addr, char *out) {
  char host[INET6_ADDRSTRLEN];
  const struct sockaddr *sa = (const struct sockaddr *)addr->addr;
  if (sa->sa_family == AF_INET6) {
    const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)sa;
    if (!inet_ntop(AF_INET6, &a->sin6_addr, host, sizeof host)) return 0;
    return (size_t)snprintf(out, 64, "[%s]:%u", host, ntohs(a->sin6_port));
  }
  if (sa->sa_family == AF_INET) {
    const struct sockaddr_in *a = (const struct sockaddr_in *)sa;
    if (!inet_ntop(AF_INET, &a->sin_addr, host, sizeof host)) return 0;
    return (size_t)snprintf(out, 64, "%s:%u", host, ntohs(a->sin_port));
  }
  return 0;
}

static char *c_string(moonbit_bytes_t b) {
  int32_t n = Moonbit_array_length(b);
  char *s = malloc((size_t)n + 1);
  if (!s) return NULL;
  memcpy(s, b, n);
  s[n] = 0;
  return s;
}

// --- ngtcp2 callbacks ------------------------------------------------------

static void rand_cb(uint8_t *dest, size_t destlen, const ngtcp2_rand_ctx *ctx) {
  (void)ctx;
  RAND_bytes(dest, (int)destlen);
}

static int new_cid_cb(ngtcp2_conn *conn, ngtcp2_cid *cid, uint8_t *token,
                      size_t cidlen, void *user) {
  (void)conn;
  qconn *q = user;
  if (RAND_bytes(cid->data, (int)cidlen) != 1) return NGTCP2_ERR_CALLBACK_FAILURE;
  cid->datalen = cidlen;
  if (ngtcp2_crypto_generate_stateless_reset_token(token, q->reset_key,
                                                   KEY_BYTES, cid) != 0)
    return NGTCP2_ERR_CALLBACK_FAILURE;
  return 0;
}

// An nghttp3 failure `rv` inside an ngtcp2 callback: the connection closes
// with the HTTP/3 error code it implies.
static int h3_failed(qconn *q, int rv) {
  ngtcp2_ccerr_set_application_error(
      &q->ccerr, nghttp3_err_infer_quic_app_error_code(rv), NULL, 0);
  return NGTCP2_ERR_CALLBACK_FAILURE;
}

static int extend_offsets(qconn *q, int64_t stream, size_t n) {
  if (n == 0) return 0;
  ngtcp2_conn_extend_max_stream_offset(q->conn, stream, n);
  ngtcp2_conn_extend_max_offset(q->conn, n);
  return 0;
}

static int recv_stream_data_cb(ngtcp2_conn *conn, uint32_t flags, int64_t stream,
                               uint64_t offset, const uint8_t *data,
                               size_t datalen, void *user, void *stream_user) {
  (void)conn;
  (void)offset;
  (void)stream_user;
  qconn *q = user;
  if (!q->h3) return 0;
  // A server learns which requests came in early data, which a replay
  // could repeat (RFC 8470): before nghttp3 reports the request.
  if (q->server && (flags & NGTCP2_STREAM_DATA_FLAG_0RTT)) {
    put_u8(&q->events, EV_EARLY);
    put_i64(&q->events, stream);
  }
  nghttp3_ssize n = nghttp3_conn_read_stream(
      q->h3, stream, data, datalen, (flags & NGTCP2_STREAM_DATA_FLAG_FIN) != 0);
  if (n < 0) {
    ngtcp2_ccerr_set_application_error(
        &q->ccerr, nghttp3_err_infer_quic_app_error_code((int)n), NULL, 0);
    return NGTCP2_ERR_CALLBACK_FAILURE;
  }
  // nghttp3's framing bytes are acknowledged at once; body bytes when
  // MoonBit takes them (`consume`).
  return extend_offsets(q, stream, (size_t)n);
}

static int acked_offset_cb(ngtcp2_conn *conn, int64_t stream, uint64_t offset,
                           uint64_t datalen, void *user, void *stream_user) {
  (void)conn;
  (void)offset;
  (void)stream_user;
  qconn *q = user;
  if (!q->h3) return 0;
  int rv = nghttp3_conn_add_ack_offset(q->h3, stream, datalen);
  return rv != 0 ? h3_failed(q, rv) : 0;
}

static int stream_close_cb(ngtcp2_conn *conn, uint32_t flags, int64_t stream,
                           uint64_t code, void *user, void *stream_user) {
  (void)stream_user;
  qconn *q = user;
  if (!(flags & NGTCP2_STREAM_CLOSE_FLAG_APP_ERROR_CODE_SET))
    code = NGHTTP3_H3_NO_ERROR;
  if (q->h3) {
    int rv = nghttp3_conn_close_stream(q->h3, stream, code);
    if (rv != 0 && rv != NGHTTP3_ERR_STREAM_NOT_FOUND) {
      ngtcp2_ccerr_set_application_error(
          &q->ccerr, nghttp3_err_infer_quic_app_error_code(rv), NULL, 0);
      return NGTCP2_ERR_CALLBACK_FAILURE;
    }
  }
  // QUIC counts the request streams a client may open over the connection's
  // whole life, not those open at once (RFC 9000, section 4.6): a server
  // gives one back for each of the client's bidirectional streams that
  // closes, or the connection would take no request after the first
  // `max_streams_bidi`.
  // A client-initiated bidirectional stream has the two low bits clear
  // (RFC 9000, section 2.1).
  if (q->server && (stream & 0x3) == 0) {
    ngtcp2_conn_extend_max_streams_bidi(conn, 1);
  }
  // The peer's unidirectional streams: a client's have the low bits 0b10,
  // a server's 0b11.
  if ((stream & 0x3) == (q->server ? 2 : 3)) {
    ngtcp2_conn_extend_max_streams_uni(conn, 1);
  }
  return 0;
}

static int stream_reset_cb(ngtcp2_conn *conn, int64_t stream, uint64_t final_size,
                           uint64_t code, void *user, void *stream_user) {
  (void)conn;
  (void)final_size;
  (void)code;
  (void)stream_user;
  qconn *q = user;
  if (!q->h3) return 0;
  int rv = nghttp3_conn_shutdown_stream_read(q->h3, stream);
  return rv != 0 ? h3_failed(q, rv) : 0;
}

static int stream_stop_sending_cb(ngtcp2_conn *conn, int64_t stream,
                                  uint64_t code, void *user, void *stream_user) {
  (void)conn;
  (void)code;
  (void)stream_user;
  qconn *q = user;
  if (!q->h3) return 0;
  int rv = nghttp3_conn_shutdown_stream_read(q->h3, stream);
  return rv != 0 ? h3_failed(q, rv) : 0;
}

static int extend_max_remote_bidi_cb(ngtcp2_conn *conn, uint64_t max,
                                     void *user) {
  (void)conn;
  qconn *q = user;
  if (q->h3) nghttp3_conn_set_max_client_streams_bidi(q->h3, max);
  return 0;
}

static int extend_max_stream_data_cb(ngtcp2_conn *conn, int64_t stream,
                                     uint64_t max, void *user,
                                     void *stream_user) {
  (void)conn;
  (void)max;
  (void)stream_user;
  qconn *q = user;
  if (!q->h3) return 0;
  int rv = nghttp3_conn_unblock_stream(q->h3, stream);
  return rv != 0 ? h3_failed(q, rv) : 0;
}

// --- nghttp3 callbacks -----------------------------------------------------

static int h3_acked_cb(nghttp3_conn *h3, int64_t stream, uint64_t datalen,
                       void *user, void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  outq *o = queue_of(q, stream);
  if (!o) return 0;
  while (datalen > 0 && o->head) {
    chunk *c = o->head;
    size_t left = c->len - c->acked;
    size_t n = datalen < left ? (size_t)datalen : left;
    c->acked += n;
    datalen -= n;
    if (c->acked == c->len) {
      o->head = c->next;
      if (!o->head) o->tail = NULL;
      free(c->data);
      free(c);
    }
  }
  return 0;
}

static int h3_stream_close_cb(nghttp3_conn *h3, int64_t stream, uint64_t code,
                              void *user, void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  queue_remove(q, stream);
  header_count_remove(&q->headers, stream);
  put_u8(&q->events, EV_CLOSED);
  put_i64(&q->events, stream);
  put_i64(&q->events, (int64_t)code);
  return 0;
}

static int h3_recv_data_cb(nghttp3_conn *h3, int64_t stream, const uint8_t *data,
                           size_t datalen, void *user, void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  put_u8(&q->events, EV_DATA);
  put_i64(&q->events, stream);
  put_blob(&q->events, data, datalen);
  return 0;
}

static int h3_deferred_consume_cb(nghttp3_conn *h3, int64_t stream,
                                  size_t consumed, void *user,
                                  void *stream_user) {
  (void)h3;
  (void)stream_user;
  return extend_offsets(user, stream, consumed);
}

static int h3_begin_headers_cb(nghttp3_conn *h3, int64_t stream, void *user,
                               void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  header_count *h = header_count_of(q->headers, stream);
  if (!h) {
    h = calloc(1, sizeof *h);
    if (!h) return NGHTTP3_ERR_NOMEM;
    h->stream = stream;
    h->next = q->headers;
    q->headers = h;
  }
  h->bytes = 0;
  h->over = 0;
  put_u8(&q->events, EV_HEADERS_BEGIN);
  put_i64(&q->events, stream);
  return 0;
}

static int h3_recv_header_cb(nghttp3_conn *h3, int64_t stream, int32_t token,
                             nghttp3_rcbuf *name, nghttp3_rcbuf *value,
                             uint8_t flags, void *user, void *stream_user) {
  (void)h3;
  (void)token;
  (void)flags;
  (void)stream_user;
  qconn *q = user;
  nghttp3_vec n = nghttp3_rcbuf_get_buf(name);
  nghttp3_vec v = nghttp3_rcbuf_get_buf(value);
  header_count *h = header_count_of(q->headers, stream);
  if (!h || h->over) return 0;
  h->bytes += n.len + v.len + 32;
  if (q->max_header_bytes > 0 && h->bytes > q->max_header_bytes) {
    put_u8(&q->events, EV_TOO_LARGE);
    put_i64(&q->events, stream);
    h->over = 1;
    // The stream ends both ways; the connection goes on.
    nghttp3_conn_shutdown_stream_read(q->h3, stream);
    ngtcp2_conn_shutdown_stream(q->conn, 0, stream,
                                NGHTTP3_H3_EXCESSIVE_LOAD);
    return 0;
  }
  put_u8(&q->events, EV_HEADER);
  put_i64(&q->events, stream);
  put_blob(&q->events, n.base, n.len);
  put_blob(&q->events, v.base, v.len);
  return 0;
}

static int h3_end_headers_cb(nghttp3_conn *h3, int64_t stream, int fin,
                             void *user, void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  header_count *h = header_count_of(q->headers, stream);
  int over = h && h->over;
  header_count_remove(&q->headers, stream);
  if (over) return 0;
  put_u8(&q->events, EV_HEADERS_END);
  put_i64(&q->events, stream);
  put_i64(&q->events, fin);
  return 0;
}

static int h3_end_stream_cb(nghttp3_conn *h3, int64_t stream, void *user,
                            void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  put_u8(&q->events, EV_END_STREAM);
  put_i64(&q->events, stream);
  return 0;
}

static int h3_stop_sending_cb(nghttp3_conn *h3, int64_t stream, uint64_t code,
                              void *user, void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  ngtcp2_conn_shutdown_stream_read(q->conn, 0, stream, code);
  return 0;
}

static int h3_reset_stream_cb(nghttp3_conn *h3, int64_t stream, uint64_t code,
                              void *user, void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  ngtcp2_conn_shutdown_stream_write(q->conn, 0, stream, code);
  return 0;
}

static int h3_shutdown_cb(nghttp3_conn *h3, int64_t id, void *user) {
  (void)h3;
  qconn *q = user;
  put_u8(&q->events, EV_GOAWAY);
  put_i64(&q->events, id);
  return 0;
}

static nghttp3_nv *fields_of(const uint8_t *blob, size_t bloblen,
                             size_t *count);

// The end of `o`'s body: EOF, and with trailers the HEADERS frame that ends
// the stream instead. 0, or an nghttp3 error.
static int body_end(qconn *q, outq *o, uint32_t *pflags) {
  *pflags |= NGHTTP3_DATA_FLAG_EOF;
  if (!o->trailers) return 0;
  size_t count;
  nghttp3_nv *nva = fields_of(o->trailers, o->trailers_len, &count);
  if (!nva) return NGHTTP3_ERR_CALLBACK_FAILURE;
  int rv = nghttp3_conn_submit_trailers(q->h3, o->stream, nva, count);
  free(nva);
  free(o->trailers);
  o->trailers = NULL;
  if (rv != 0) return NGHTTP3_ERR_CALLBACK_FAILURE;
  *pflags |= NGHTTP3_DATA_FLAG_NO_END_STREAM;
  return 0;
}

static nghttp3_ssize h3_read_data_cb(nghttp3_conn *h3, int64_t stream,
                                     nghttp3_vec *vec, size_t veccnt,
                                     uint32_t *pflags, void *user,
                                     void *stream_user) {
  (void)h3;
  (void)stream_user;
  qconn *q = user;
  outq *o = queue_of(q, stream);
  if (!o) {
    *pflags |= NGHTTP3_DATA_FLAG_EOF;
    return 0;
  }
  size_t n = 0;
  for (chunk *c = o->head; c && n < veccnt; c = c->next) {
    if (c->sent == c->len) continue;
    vec[n].base = c->data + c->sent;
    vec[n].len = c->len - c->sent;
    o->queued -= c->len - c->sent;
    c->sent = c->len;
    n++;
  }
  if (o->queued < q->low && !o->drained && !o->ended) {
    o->drained = 1;
    put_u8(&q->events, EV_DRAINED);
    put_i64(&q->events, stream);
  }
  if (n == 0 && o->queued == 0) {
    if (o->ended) {
      int rv = body_end(q, o, pflags);
      return rv != 0 ? rv : 0;
    }
    return NGHTTP3_ERR_WOULDBLOCK;
  }
  if (o->queued == 0 && o->ended) {
    int rv = body_end(q, o, pflags);
    if (rv != 0) return rv;
  }
  return (nghttp3_ssize)n;
}

// --- the HTTP/3 layer, once the handshake completed -------------------------

static int setup_h3(qconn *q) {
  nghttp3_callbacks cb = {0};
  cb.acked_stream_data = h3_acked_cb;
  cb.stream_close = h3_stream_close_cb;
  cb.recv_data = h3_recv_data_cb;
  cb.deferred_consume = h3_deferred_consume_cb;
  cb.begin_headers = h3_begin_headers_cb;
  cb.recv_header = h3_recv_header_cb;
  cb.end_headers = h3_end_headers_cb;
  // A trailer section is recorded as another header section, under the
  // same bound; the stream's reader knows it by the head before it.
  cb.begin_trailers = h3_begin_headers_cb;
  cb.recv_trailer = h3_recv_header_cb;
  cb.end_trailers = h3_end_headers_cb;
  cb.stop_sending = h3_stop_sending_cb;
  cb.end_stream = h3_end_stream_cb;
  cb.reset_stream = h3_reset_stream_cb;
  cb.shutdown = h3_shutdown_cb;
  nghttp3_settings settings;
  nghttp3_settings_default(&settings);
  settings.max_field_section_size = q->max_header_bytes;
  settings.qpack_max_dtable_capacity = 4096;
  settings.qpack_blocked_streams = 100;
  int rv = q->server
               ? nghttp3_conn_server_new(&q->h3, &cb, &settings, NULL, q)
               : nghttp3_conn_client_new(&q->h3, &cb, &settings, NULL, q);
  if (rv != 0) return rv;
  if (q->server) nghttp3_conn_set_max_client_streams_bidi(q->h3, q->max_streams_bidi);
  int64_t ctrl, enc, dec;
  if (ngtcp2_conn_open_uni_stream(q->conn, &ctrl, NULL) != 0 ||
      ngtcp2_conn_open_uni_stream(q->conn, &enc, NULL) != 0 ||
      ngtcp2_conn_open_uni_stream(q->conn, &dec, NULL) != 0)
    return -1;
  if (nghttp3_conn_bind_control_stream(q->h3, ctrl) != 0 ||
      nghttp3_conn_bind_qpack_streams(q->h3, enc, dec) != 0)
    return -1;
  return 0;
}

// --- 0-RTT -------------------------------------------------------------------

// What a server stamps into a ticket and requires of one for early data:
// the QUIC version and its settings. Early data obeys the limits of the
// connection the ticket came from (RFC 9000, section 7.4.1), so a server
// whose settings changed since takes the ticket for a full handshake only.
static size_t ticket_stamp(qconn *q, uint8_t *out) {
#if NGTCP2_VERSION_NUM >= 0x011700
  uint32_t version = ngtcp2_conn_get_negotiated_version2(q->conn);
#else
  uint32_t version = ngtcp2_conn_get_negotiated_version(q->conn);
#endif
  memcpy(out, &version, sizeof version);
  memcpy(out + sizeof version, q->values, sizeof q->values);
  return sizeof version + sizeof q->values;
}

static int gen_ticket_cb(SSL *ssl, void *arg) {
  (void)arg;
  ngtcp2_crypto_conn_ref *ref = SSL_get_app_data(ssl);
  if (!ref) return 0;
  qconn *q = ref->user_data;
  uint8_t stamp[64];
  size_t n = ticket_stamp(q, stamp);
  return SSL_SESSION_set1_ticket_appdata(SSL_get0_session(ssl), stamp, n);
}

static SSL_TICKET_RETURN decrypt_ticket_cb(SSL *ssl, SSL_SESSION *session,
                                           const unsigned char *keyname,
                                           size_t keynamelen,
                                           SSL_TICKET_STATUS status, void *arg) {
  (void)keyname;
  (void)keynamelen;
  (void)arg;
  if (status == SSL_TICKET_EMPTY || status == SSL_TICKET_NO_DECRYPT)
    return SSL_TICKET_RETURN_IGNORE_RENEW;
  int renew = status == SSL_TICKET_SUCCESS_RENEW;
  ngtcp2_crypto_conn_ref *ref = SSL_get_app_data(ssl);
  void *data;
  size_t len;
  uint8_t stamp[64];
  if (!ref || !SSL_SESSION_get0_ticket_appdata(session, &data, &len) ||
      len != ticket_stamp(ref->user_data, stamp) || memcmp(data, stamp, len) != 0)
    return renew ? SSL_TICKET_RETURN_IGNORE_RENEW : SSL_TICKET_RETURN_IGNORE;
  return renew ? SSL_TICKET_RETURN_USE_RENEW : SSL_TICKET_RETURN_USE;
}

// A client's ticket, with the server's transport parameters that early
// data on it must keep to (RFC 9000, section 7.4.1).
static int new_session_cb(SSL *ssl, SSL_SESSION *session) {
  ngtcp2_crypto_conn_ref *ref = SSL_get_app_data(ssl);
  if (!ref) return 0;
  qconn *q = ref->user_data;
  if (!q->conn) return 0;
  int n = i2d_SSL_SESSION(session, NULL);
  if (n <= 0) return 0;
  uint8_t *der = malloc((size_t)n);
  if (!der) return 0;
  uint8_t *p = der;
  i2d_SSL_SESSION(session, &p);
#if NGTCP2_VERSION_NUM >= 0x011700
  ngtcp2_ssize tp = ngtcp2_conn_encode_0rtt_transport_params2(q->conn, q->tp,
                                                               sizeof q->tp);
#else
  ngtcp2_ssize tp = ngtcp2_conn_encode_0rtt_transport_params(q->conn, q->tp,
                                                              sizeof q->tp);
#endif
  if (tp < 0) {
    free(der);
    return 0;
  }
  free(q->ticket);
  q->ticket = der;
  q->ticket_len = (size_t)n;
  q->tp_len = (size_t)tp;
  put_u8(&q->events, EV_TICKET);
  // 0: OpenSSL keeps no reference to the session.
  return 0;
}

// The server rejected this client's early data: ngtcp2 discards the
// streams opened in 0-RTT, so the HTTP/3 layer over them goes too and is
// made again over 1-RTT; their requests are MoonBit's to send again.
static int early_data_rejected_cb(ngtcp2_conn *conn, void *user) {
  (void)conn;
  qconn *q = user;
  if (q->h3) nghttp3_conn_del(q->h3);
  q->h3 = NULL;
  while (q->headers) header_count_remove(&q->headers, q->headers->stream);
  outq *o = q->queues;
  while (o) {
    outq *next = o->next;
    outq_free(o);
    o = next;
  }
  q->queues = NULL;
  q->early_rejected = 1;
  put_u8(&q->events, EV_EARLY_REJECTED);
  return 0;
}

// A server's HTTP/3 layer is made with its 1-RTT keys, before the
// handshake completes, so that requests a client sent in 0-RTT find it.
static int recv_tx_key_cb(ngtcp2_conn *conn, ngtcp2_encryption_level level,
                          void *user) {
  (void)conn;
  qconn *q = user;
  if (level != NGTCP2_ENCRYPTION_LEVEL_1RTT || !q->server || q->h3) return 0;
  return setup_h3(q) != 0 ? NGTCP2_ERR_CALLBACK_FAILURE : 0;
}

static int handshake_completed_cb(ngtcp2_conn *conn, void *user) {
  (void)conn;
  qconn *q = user;
  q->handshake = 1;
  // OpenSSL tells a client whether the server took its early data only
  // now; ngtcp2 then discards the 0-RTT streams (`early_data_rejected_cb`).
  if (q->early && SSL_get_early_data_status(q->ssl) != SSL_EARLY_DATA_ACCEPTED &&
      ngtcp2_conn_tls_early_data_rejected(q->conn) != 0)
    return NGTCP2_ERR_CALLBACK_FAILURE;
  if (!q->h3 && setup_h3(q) != 0) return NGTCP2_ERR_CALLBACK_FAILURE;
  put_u8(&q->events, EV_HANDSHAKE);
  return 0;
}

// --- creating connections --------------------------------------------------

// Settings, in the order connection.mbt passes them.
typedef struct {
  int64_t max_streams_bidi; // a server's limit on client streams
  int64_t stream_window;
  int64_t connection_window;
  int64_t max_header_list;
  int64_t low_mark;
  int64_t idle_timeout_ms;
} config;

static void fill_callbacks(ngtcp2_callbacks *cb, int server) {
  memset(cb, 0, sizeof *cb);
  if (server) {
    cb->recv_client_initial = ngtcp2_crypto_recv_client_initial_cb;
  } else {
    cb->client_initial = ngtcp2_crypto_client_initial_cb;
    cb->recv_retry = ngtcp2_crypto_recv_retry_cb;
  }
  cb->recv_crypto_data = ngtcp2_crypto_recv_crypto_data_cb;
  cb->encrypt = ngtcp2_crypto_encrypt_cb;
  cb->decrypt = ngtcp2_crypto_decrypt_cb;
  cb->hp_mask = ngtcp2_crypto_hp_mask_cb;
  cb->update_key = ngtcp2_crypto_update_key_cb;
  cb->delete_crypto_aead_ctx = ngtcp2_crypto_delete_crypto_aead_ctx_cb;
  cb->delete_crypto_cipher_ctx = ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
  cb->get_path_challenge_data = ngtcp2_crypto_get_path_challenge_data_cb;
  cb->version_negotiation = ngtcp2_crypto_version_negotiation_cb;
  cb->rand = rand_cb;
  cb->get_new_connection_id = new_cid_cb;
  cb->handshake_completed = handshake_completed_cb;
  if (server) {
    cb->recv_tx_key = recv_tx_key_cb;
  } else {
    cb->tls_early_data_rejected = early_data_rejected_cb;
  }
  cb->recv_stream_data = recv_stream_data_cb;
  cb->acked_stream_data_offset = acked_offset_cb;
  cb->stream_close = stream_close_cb;
  cb->stream_reset = stream_reset_cb;
  cb->stream_stop_sending = stream_stop_sending_cb;
  cb->extend_max_remote_streams_bidi = extend_max_remote_bidi_cb;
  cb->extend_max_stream_data = extend_max_stream_data_cb;
}

static void fill_params(ngtcp2_transport_params *params, const config *c,
                        int server) {
  ngtcp2_transport_params_default(params);
  params->initial_max_data = (uint64_t)c->connection_window;
  params->initial_max_stream_data_bidi_local = (uint64_t)c->stream_window;
  params->initial_max_stream_data_bidi_remote = (uint64_t)c->stream_window;
  params->initial_max_stream_data_uni = (uint64_t)c->stream_window;
  // A client opens no stream of the server's kind; a server limits them.
  params->initial_max_streams_bidi = server ? (uint64_t)c->max_streams_bidi : 0;
  // Control and two QPACK streams, and room for streams of types nghttp3
  // reads and drops (GREASE, RFC 9114, section 6.2.3); the peer's that
  // close are given back.
  params->initial_max_streams_uni = 16;
  params->max_idle_timeout = (uint64_t)c->idle_timeout_ms * NGTCP2_MILLISECONDS;
  // A client's connected UDP socket has one path; a server routes datagrams
  // by connection ID, so its clients may move.
  params->disable_active_migration = server ? 0 : 1;
}

static qconn *qconn_new(int server, const int64_t *values) {
  qconn *q = calloc(1, sizeof *q);
  if (!q) return NULL;
  q->server = server;
  q->low = values[4] > 0 ? (size_t)values[4] : 16384;
  q->max_header_bytes = values[3] > 0 ? (size_t)values[3] : 0;
  q->max_streams_bidi = (uint64_t)values[0];
  memcpy(q->values, values, sizeof q->values);
  if (RAND_bytes(q->reset_key, KEY_BYTES) != 1) {
    free(q);
    return NULL;
  }
  ngtcp2_ccerr_default(&q->ccerr);
  q->ref.get_conn = get_conn;
  q->ref.user_data = q;
  return q;
}

// An empty `local` is the any-address of the remote's family: a client's
// connected UDP socket has one path, and ngtcp2 needs only the same path on
// every packet, not the address the kernel chose.
static int set_path(qconn *q, const char *local, const char *remote) {
  if (parse_addr(remote, &q->remote) != 0) return -1;
  if (local[0] == 0) {
    memset(&q->local, 0, sizeof q->local);
    q->local.ss_family = q->remote.ss_family;
  } else if (parse_addr(local, &q->local) != 0) {
    return -1;
  }
  q->path.local.addr = (ngtcp2_sockaddr *)&q->local;
  q->path.local.addrlen = addr_len(&q->local);
  q->path.remote.addr = (ngtcp2_sockaddr *)&q->remote;
  q->path.remote.addrlen = addr_len(&q->remote);
  return 0;
}

static qconn_box *box(qconn *q) {
  qconn_box *b =
      moonbit_make_external_object(qconn_box_finalize, sizeof(qconn_box));
  b->q = q;
  return b;
}

static int is_ip_literal(const char *host) {
  ASN1_OCTET_STRING *ip = a2i_IPADDRESS(host);
  if (!ip) {
    ERR_clear_error();
    return 0;
  }
  ASN1_OCTET_STRING_free(ip);
  return 1;
}

// A client connection to `host` (SNI and the certificate's identity) at
// `remote`, from `local`, both `host:port` with IPv6 in brackets.
// Resumes the session in `resume` (`mttp_ng_h3_resumption`'s: the ticket's
// length in four bytes, the ticket, then the server's transport
// parameters) and, when the ticket allows early data and the parameters
// decode, sends requests in 0-RTT: the HTTP/3 layer is made now, over the
// remembered parameters. A resumption that does not parse resumes nothing;
// the connection goes on with a full handshake.
static void resume_session(qconn *q, moonbit_bytes_t resume) {
  size_t len = (size_t)Moonbit_array_length(resume);
  if (len < 4) return;
  size_t ticket_len = ((size_t)resume[0] << 24) | ((size_t)resume[1] << 16) |
                      ((size_t)resume[2] << 8) | resume[3];
  if (ticket_len > len - 4) return;
  const uint8_t *p = resume + 4;
  SSL_SESSION *session = d2i_SSL_SESSION(NULL, &p, (long)ticket_len);
  if (!session) {
    ERR_clear_error();
    return;
  }
  int ok = SSL_set_session(q->ssl, session);
  uint32_t max_early = SSL_SESSION_get_max_early_data(session);
  SSL_SESSION_free(session);
  if (!ok || max_early == 0) return;
  const uint8_t *tp = resume + 4 + ticket_len;
  if (ngtcp2_conn_decode_and_set_0rtt_transport_params(
          q->conn, tp, len - 4 - ticket_len) != 0)
    return;
  if (setup_h3(q) != 0) return;
  SSL_set_quic_tls_early_data_enabled(q->ssl, 1);
  q->early = 1;
}

MOONBIT_FFI_EXPORT qconn_box *mttp_ng_h3_client_new(
    context_box *cb, moonbit_bytes_t host_b, moonbit_bytes_t local_b,
    moonbit_bytes_t remote_b, int64_t *values, moonbit_bytes_t resume) {
  qconn *q = qconn_new(0, values);
  if (!q) return box(NULL);
  config c = {values[0], values[1], values[2], values[3], values[4], values[5]};
  char *host = c_string(host_b), *local = c_string(local_b),
       *remote = c_string(remote_b);
  int ok = host && local && remote && cb->c && cb->c->ctx &&
           set_path(q, local, remote) == 0;
  if (!ok) {
    snprintf(q->error, ERROR_CAPACITY, "invalid client configuration");
    goto done;
  }
  ERR_clear_error();
  q->ssl = SSL_new(cb->c->ctx);
  if (!q->ssl) {
    record_error(q->error, "SSL_new failed");
    goto done;
  }
  SSL_set_app_data(q->ssl, &q->ref);
  SSL_set_connect_state(q->ssl);
  SSL_set_alpn_protos(q->ssl, h3_alpn, sizeof h3_alpn);
  if (is_ip_literal(host)) {
    X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(q->ssl), host);
  } else {
    SSL_set_tlsext_host_name(q->ssl, host);
    SSL_set1_host(q->ssl, host);
  }
  if (ngtcp2_crypto_ossl_configure_client_session(q->ssl) != 0 ||
      ngtcp2_crypto_ossl_ctx_new(&q->ossl, q->ssl) != 0) {
    record_error(q->error, "cannot configure the QUIC TLS session");
    goto done;
  }
  ngtcp2_cid dcid, scid;
  dcid.datalen = NGTCP2_MIN_INITIAL_DCIDLEN + 2;
  scid.datalen = 17;
  RAND_bytes(dcid.data, (int)dcid.datalen);
  RAND_bytes(scid.data, (int)scid.datalen);
  ngtcp2_callbacks callbacks;
  fill_callbacks(&callbacks, 0);
  ngtcp2_settings settings;
  ngtcp2_settings_default(&settings);
  settings.initial_ts = now_ns();
  settings.max_tx_udp_payload_size = MAX_DATAGRAM;
  // Every packet is acknowledged with the next datagram, which the reader
  // sends after each read. A client connection runs only while someone
  // waits on it, so a delayed acknowledgement (two packets, or
  // max_ack_delay later by default) of the last packets of a response
  // would wait for the next request; the server, which keeps a stream
  // until its data is acknowledged, would wait for it to time out.
  settings.ack_thresh = 1;
  ngtcp2_transport_params params;
  fill_params(&params, &c, 0);
  int rv = ngtcp2_conn_client_new(&q->conn, &dcid, &scid, &q->path,
                                  NGTCP2_PROTO_VER_V1, &callbacks, &settings,
                                  &params, NULL, q);
  if (rv != 0) {
    snprintf(q->error, ERROR_CAPACITY, "ngtcp2_conn_client_new: %s",
             ngtcp2_strerror(rv));
    goto done;
  }
  ngtcp2_conn_set_tls_native_handle(q->conn, q->ossl);
  if (Moonbit_array_length(resume) > 0) resume_session(q, resume);
done:
  free(host);
  free(local);
  free(remote);
  return box(q);
}

// A Version Negotiation packet for `data` when it is a long header packet
// of a version this server does not speak, in a datagram large enough to
// start a connection (RFC 9000, sections 6.1 and 14.1); empty otherwise.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_version_negotiation(
    moonbit_bytes_t data) {
  size_t len = (size_t)Moonbit_array_length(data);
  ngtcp2_version_cid vc;
  if (len < 1200 ||
      ngtcp2_pkt_decode_version_cid(&vc, data, len, 0) !=
          NGTCP2_ERR_VERSION_NEGOTIATION)
    return moonbit_make_bytes(0, 0);
  uint8_t buf[256];
  uint8_t random;
  RAND_bytes(&random, 1);
  uint32_t versions[] = {NGTCP2_PROTO_VER_V1};
  ngtcp2_ssize n = ngtcp2_pkt_write_version_negotiation(
      buf, sizeof buf, random, vc.scid, vc.scidlen, vc.dcid, vc.dcidlen,
      versions, 1);
  if (n < 0) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  memcpy(out, buf, (size_t)n);
  return out;
}

// A server connection for the client Initial packet `data`, from `remote`
// to `local`; a failed box when the packet does not start a connection.
MOONBIT_FFI_EXPORT qconn_box *mttp_ng_h3_server_new(
    context_box *cb, moonbit_bytes_t data, moonbit_bytes_t local_b,
    moonbit_bytes_t remote_b, int64_t *values, moonbit_bytes_t keys) {
  qconn *q = qconn_new(1, values);
  if (!q) return box(NULL);
  if (Moonbit_array_length(keys) != SERVER_KEYS_BYTES) {
    snprintf(q->error, ERROR_CAPACITY, "server keys of the wrong length");
    return box(q);
  }
  memcpy(q->reset_key, keys, KEY_BYTES);
  const uint8_t *retry_key = keys + KEY_BYTES;
  config c = {values[0], values[1], values[2], values[3], values[4], values[5]};
  char *local = c_string(local_b), *remote = c_string(remote_b);
  ngtcp2_pkt_hd hd;
  int ok = local && remote && cb->c && cb->c->ctx &&
           set_path(q, local, remote) == 0 &&
           ngtcp2_accept(&hd, data, (size_t)Moonbit_array_length(data)) == 0;
  if (!ok) {
    snprintf(q->error, ERROR_CAPACITY, "not a client Initial packet");
    goto done;
  }
  // A Retry token (`mttp_ng_h3_answer_initial` sent the Retry) proves the
  // client's address and names the DCID of its first Initial; any other
  // token is none this server issued, and is ignored.
  ngtcp2_cid odcid = hd.dcid;
  int retried = hd.tokenlen > 0 && hd.token[0] == NGTCP2_CRYPTO_TOKEN_MAGIC_RETRY;
  if (retried &&
      ngtcp2_crypto_verify_retry_token(
          &odcid, hd.token, hd.tokenlen, retry_key, KEY_BYTES,
          hd.version, (ngtcp2_sockaddr *)&q->remote, addr_len(&q->remote),
          &hd.dcid, RETRY_TOKEN_TIMEOUT, now_ns()) != 0) {
    snprintf(q->error, ERROR_CAPACITY, "an invalid Retry token");
    goto done;
  }
  ERR_clear_error();
  q->ssl = SSL_new(cb->c->ctx);
  if (!q->ssl) {
    record_error(q->error, "SSL_new failed");
    goto done;
  }
  SSL_set_app_data(q->ssl, &q->ref);
  SSL_set_accept_state(q->ssl);
  if (ngtcp2_crypto_ossl_configure_server_session(q->ssl) != 0 ||
      ngtcp2_crypto_ossl_ctx_new(&q->ossl, q->ssl) != 0) {
    record_error(q->error, "cannot configure the QUIC TLS session");
    goto done;
  }
  if (cb->c->early) SSL_set_quic_tls_early_data_enabled(q->ssl, 1);
  ngtcp2_cid scid;
  scid.datalen = SERVER_CIDLEN;
  RAND_bytes(scid.data, (int)scid.datalen);
  ngtcp2_callbacks callbacks;
  fill_callbacks(&callbacks, 1);
  ngtcp2_settings settings;
  ngtcp2_settings_default(&settings);
  settings.initial_ts = now_ns();
  settings.max_tx_udp_payload_size = MAX_DATAGRAM;
  // ngtcp2 takes a token passed here as the client's address validated,
  // lifting the three-times limit on what is sent to an unproven address
  // (RFC 9000, section 8), so only a verified Retry token is passed; this
  // server issues no NEW_TOKEN.
  if (retried) {
    settings.token = hd.token;
    settings.tokenlen = hd.tokenlen;
    settings.token_type = NGTCP2_TOKEN_TYPE_RETRY;
  }
  ngtcp2_transport_params params;
  fill_params(&params, &c, 1);
  params.original_dcid = odcid;
  params.original_dcid_present = 1;
  if (retried) {
    params.retry_scid = hd.dcid;
    params.retry_scid_present = 1;
  }
  // The reset token of the first connection ID (those issued later carry
  // theirs in NEW_CONNECTION_ID, `new_cid_cb`): without it a client cannot
  // tell this server's Stateless Reset for that ID from noise.
  if (ngtcp2_crypto_generate_stateless_reset_token(
          params.stateless_reset_token, q->reset_key, KEY_BYTES,
          &scid) != 0) {
    snprintf(q->error, ERROR_CAPACITY, "cannot make a stateless reset token");
    goto done;
  }
  params.stateless_reset_token_present = 1;
  int rv = ngtcp2_conn_server_new(&q->conn, &hd.scid, &scid, &q->path,
                                  hd.version, &callbacks, &settings, &params,
                                  NULL, q);
  if (rv != 0) {
    snprintf(q->error, ERROR_CAPACITY, "ngtcp2_conn_server_new: %s",
             ngtcp2_strerror(rv));
    goto done;
  }
  ngtcp2_conn_set_tls_native_handle(q->conn, q->ossl);
done:
  free(local);
  free(remote);
  return box(q);
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_failed(qconn_box *b) {
  return !b->q || !b->q->conn;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_error(qconn_box *b) {
  return to_bytes(b->q ? b->q->error : "out of memory");
}

MOONBIT_FFI_EXPORT void mttp_ng_h3_free(qconn_box *b) {
  qconn_free(b->q);
  b->q = NULL;
}

// --- steps -----------------------------------------------------------------

// The connection close the peer sent. ngtcp2 1.23 renamed the getter
// (the old one is deprecated there); Debian 13's backport is 1.22.
static const ngtcp2_ccerr *peer_ccerr(ngtcp2_conn *conn) {
#if NGTCP2_VERSION_NUM >= 0x011700
  return ngtcp2_conn_get_ccerr2(conn);
#else
  return ngtcp2_conn_get_ccerr(conn);
#endif
}

// The getters ngtcp2 1.23 made const and renamed (the old ones are
// deprecated there); Debian 13's backport is 1.22.
static ngtcp2_duration conn_pto(ngtcp2_conn *conn) {
#if NGTCP2_VERSION_NUM >= 0x011700
  return ngtcp2_conn_get_pto2(conn);
#else
  return ngtcp2_conn_get_pto(conn);
#endif
}

static const ngtcp2_path *conn_path(ngtcp2_conn *conn) {
#if NGTCP2_VERSION_NUM >= 0x011700
  return ngtcp2_conn_get_path2(conn);
#else
  return ngtcp2_conn_get_path(conn);
#endif
}

static size_t conn_scids(ngtcp2_conn *conn, ngtcp2_cid *dest) {
#if NGTCP2_VERSION_NUM >= 0x011700
  return ngtcp2_conn_get_scid2(conn, dest);
#else
  return ngtcp2_conn_get_scid(conn, dest);
#endif
}

// Appends a datagram of `n` bytes for `remote` to the output: its length in
// two bytes, its destination's text in one byte and the text, then the
// datagram. A client's connected socket sends where it is connected; a
// server sends each to its own destination, which changes when the client
// migrates (or its NAT rebinds) and differs while a new path is validated.
static void put_datagram(qconn *q, const ngtcp2_addr *remote, const uint8_t *buf,
                         size_t n) {
  char text[64];
  size_t textlen = format_addr(remote, text);
  uint8_t head[3] = {(uint8_t)(n >> 8), (uint8_t)n, (uint8_t)textlen};
  buffer_put(&q->out, head, 3);
  buffer_put(&q->out, text, textlen);
  buffer_put(&q->out, buf, n);
}

// Records the close: with the peer's code when the peer closed, with this
// end's otherwise.
static void note_close(qconn *q, int by_peer) {
  if (q->closed) return;
  q->closed = 1;
  q->by_peer = by_peer;
  uint64_t code = by_peer && q->conn ? peer_ccerr(q->conn)->error_code
                                     : q->ccerr.error_code;
  put_u8(&q->events, EV_CLOSE);
  put_i64(&q->events, (int64_t)code);
  put_i64(&q->events, by_peer);
}

// Writes CONNECTION_CLOSE for q->ccerr into the output, once.
static void write_close(qconn *q) {
  if (q->closed || !q->conn) return;
  if (ngtcp2_conn_in_closing_period(q->conn) ||
      ngtcp2_conn_in_draining_period(q->conn)) {
    note_close(q, 0);
    return;
  }
  uint8_t buf[MAX_DATAGRAM];
  ngtcp2_path_storage ps;
  ngtcp2_path_storage_zero(&ps);
  ngtcp2_ssize n = ngtcp2_conn_write_connection_close(
      q->conn, &ps.path, NULL, buf, sizeof buf, &q->ccerr, now_ns());
  if (n > 0) {
    put_datagram(q, &conn_path(q->conn)->remote, buf, (size_t)n);
    // Kept for the closing period, in which a server sends it again
    // (RFC 9000, section 10.2.1).
    free(q->close_pkt);
    q->close_pkt = malloc((size_t)n);
    if (q->close_pkt) {
      memcpy(q->close_pkt, buf, (size_t)n);
      q->close_len = (size_t)n;
    }
  }
  note_close(q, 0);
}

static void fail_lib(qconn *q, int rv) {
  if (rv == NGTCP2_ERR_CRYPTO) {
    ngtcp2_ccerr_set_tls_alert(&q->ccerr, ngtcp2_conn_get_tls_alert(q->conn),
                               NULL, 0);
  } else if (q->ccerr.error_code == 0) {
    ngtcp2_ccerr_set_liberr(&q->ccerr, rv, NULL, 0);
  }
  snprintf(q->error, ERROR_CAPACITY, "%s", ngtcp2_strerror(rv));
}

// Processes one datagram from `from_b` (the connection's first remote
// address when empty): 0, or an ngtcp2 error, after which the connection
// closed (the CONNECTION_CLOSE to send is in the output). A datagram from
// another address is the client's migration or its NAT's rebinding, which
// ngtcp2 validates before it sends there more than its limit allows.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_read(qconn_box *b, moonbit_bytes_t data,
                                           moonbit_bytes_t from_b) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed) return NGTCP2_ERR_INVALID_STATE;
  ngtcp2_path path = q->path;
  struct sockaddr_storage from;
  int32_t fromlen = Moonbit_array_length(from_b);
  if (fromlen > 0) {
    char text[128];
    if (fromlen >= (int32_t)sizeof text) return NGTCP2_ERR_INVALID_ARGUMENT;
    memcpy(text, from_b, (size_t)fromlen);
    text[fromlen] = 0;
    if (parse_addr(text, &from) != 0) return NGTCP2_ERR_INVALID_ARGUMENT;
    path.remote.addr = (ngtcp2_sockaddr *)&from;
    path.remote.addrlen = addr_len(&from);
  }
  ngtcp2_pkt_info pi = {0};
  ERR_clear_error();
  int rv = ngtcp2_conn_read_pkt(q->conn, &path, &pi, data,
                                (size_t)Moonbit_array_length(data), now_ns());
  if (rv == 0) return 0;
  if (rv == NGTCP2_ERR_DRAINING) {
    // The peer closed the connection.
    snprintf(q->error, ERROR_CAPACITY, "the peer closed the QUIC connection");
    note_close(q, 1);
    return rv;
  }
  fail_lib(q, rv);
  write_close(q);
  return rv;
}

// Serializes what the connection has to send now: datagrams, each after its
// length in two bytes. 0, or an ngtcp2 error after which the connection
// closed.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_write(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed) return 0;
  uint64_t ts = now_ns();
  ngtcp2_path_storage ps;
  ngtcp2_path_storage_zero(&ps);
  uint8_t buf[MAX_DATAGRAM];
  for (int count = 0; count < DATAGRAMS_PER_WRITE;) {
    int64_t stream = -1;
    int fin = 0;
    nghttp3_vec vec[16];
    nghttp3_ssize veccnt = 0;
    if (q->h3 && ngtcp2_conn_get_max_data_left(q->conn)) {
      veccnt = nghttp3_conn_writev_stream(q->h3, &stream, &fin, vec, 16);
      if (veccnt < 0) {
        ngtcp2_ccerr_set_application_error(
            &q->ccerr, nghttp3_err_infer_quic_app_error_code((int)veccnt), NULL,
            0);
        write_close(q);
        return (int32_t)veccnt;
      }
    }
    ngtcp2_ssize ndatalen = -1;
    uint32_t flags = NGTCP2_WRITE_STREAM_FLAG_MORE;
    if (fin) flags |= NGTCP2_WRITE_STREAM_FLAG_FIN;
    // ngtcp2 encodes the FIN only with all the data offered, so the stream
    // ended in this write only when `ndatalen` covers every vector.
    uint64_t offered = 0;
    for (nghttp3_ssize i = 0; i < veccnt; ++i) offered += vec[i].len;
    ngtcp2_ssize n = ngtcp2_conn_writev_stream(
        q->conn, &ps.path, NULL, buf, sizeof buf, &ndatalen, flags, stream,
        (const ngtcp2_vec *)vec, (size_t)veccnt, ts);
    if (n < 0) {
      switch (n) {
      case NGTCP2_ERR_STREAM_DATA_BLOCKED:
        nghttp3_conn_block_stream(q->h3, stream);
        continue;
      // A stream that can take no more, or that is gone (reset and
      // closed): nghttp3 stops offering it, and the other streams go on.
      case NGTCP2_ERR_STREAM_SHUT_WR:
      case NGTCP2_ERR_STREAM_NOT_FOUND:
        nghttp3_conn_shutdown_stream_write(q->h3, stream);
        continue;
      case NGTCP2_ERR_WRITE_MORE: {
        int rv = nghttp3_conn_add_write_offset(q->h3, stream, (uint64_t)ndatalen);
        if (rv != 0) {
          h3_failed(q, rv);
          write_close(q);
          return NGTCP2_ERR_CALLBACK_FAILURE;
        }
        if (stream >= 0) {
          put_u8(&q->events, EV_SENT);
          put_i64(&q->events, stream);
          put_i64(&q->events, fin && (uint64_t)ndatalen == offered);
        }
        continue;
      }
      default:
        fail_lib(q, (int)n);
        write_close(q);
        return (int32_t)n;
      }
    }
    if (ndatalen >= 0 && stream >= 0) {
      int rv = nghttp3_conn_add_write_offset(q->h3, stream, (uint64_t)ndatalen);
      if (rv != 0) {
        h3_failed(q, rv);
        write_close(q);
        return NGTCP2_ERR_CALLBACK_FAILURE;
      }
      put_u8(&q->events, EV_SENT);
      put_i64(&q->events, stream);
      put_i64(&q->events, fin && (uint64_t)ndatalen == offered);
    }
    if (n == 0) break;
    put_datagram(q, &ps.path.remote, buf, (size_t)n);
    count++;
  }
  ngtcp2_conn_update_pkt_tx_time(q->conn, ts);
  return 0;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_output(qconn_box *b) {
  if (!b->q) return moonbit_make_bytes(0, 0);
  return take_buffer(&b->q->out);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_events(qconn_box *b) {
  if (!b->q) return moonbit_make_bytes(0, 0);
  return take_buffer(&b->q->events);
}

// Milliseconds until the timers next expire (0: now), or -1 for none.
MOONBIT_FFI_EXPORT int64_t mttp_ng_h3_expiry_ms(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed) return -1;
  uint64_t expiry = ngtcp2_conn_get_expiry(q->conn);
  if (expiry == UINT64_MAX) return -1;
  uint64_t now = now_ns();
  if (expiry <= now) return 0;
  return (int64_t)((expiry - now + NGTCP2_MILLISECONDS - 1) / NGTCP2_MILLISECONDS);
}

// Handles expired timers: 0, or an ngtcp2 error after which the connection
// closed (by its idle timeout, or the handshake's).
MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_on_expiry(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed) return 0;
  int rv = ngtcp2_conn_handle_expiry(q->conn, now_ns());
  if (rv == 0) return 0;
  if (rv == NGTCP2_ERR_IDLE_CLOSE) {
    snprintf(q->error, ERROR_CAPACITY, "the QUIC connection was idle too long");
    note_close(q, 0);
    return rv;
  }
  fail_lib(q, rv);
  write_close(q);
  return rv;
}

// Closes the connection with an application error `code` (H3_NO_ERROR for a
// clean close): CONNECTION_CLOSE goes into the output.
MOONBIT_FFI_EXPORT void mttp_ng_h3_close(qconn_box *b, int64_t code) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed) return;
  ngtcp2_ccerr_set_application_error(&q->ccerr, (uint64_t)code, NULL, 0);
  write_close(q);
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_closed(qconn_box *b) {
  return !b->q || !b->q->conn || b->q->closed;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_handshake_done(qconn_box *b) {
  return b->q && b->q->handshake;
}

// Milliseconds until the connection's idle timeout ends it, or -1.
// The request streams the server lets this client open now: its
// MAX_STREAMS less the streams opened. 0 before the handshake.
MOONBIT_FFI_EXPORT int64_t mttp_ng_h3_streams_left(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed) return 0;
  return (int64_t)ngtcp2_conn_get_streams_bidi_left(q->conn);
}

MOONBIT_FFI_EXPORT int64_t mttp_ng_h3_idle_ms(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed) return 0;
  ngtcp2_duration timeout = conn_pto(q->conn) * 3;
  const ngtcp2_transport_params *params =
      ngtcp2_conn_get_remote_transport_params(q->conn);
  uint64_t idle = params && params->max_idle_timeout
                      ? params->max_idle_timeout
                      : 30 * NGTCP2_SECONDS;
  if (timeout > idle) idle = timeout;
  return (int64_t)(idle / NGTCP2_MILLISECONDS);
}

// --- requests and responses --------------------------------------------------

// The fields point into the blob.
static nghttp3_nv *fields_of(const uint8_t *blob, size_t bloblen,
                             size_t *count) {
  const uint8_t *p = blob;
  const uint8_t *end = blob + bloblen;
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
  nghttp3_nv *nva = calloc(n ? n : 1, sizeof *nva);
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
    nva[i].flags = NGHTTP3_NV_FLAG_NONE;
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

static nghttp3_nv *fields(moonbit_bytes_t blob, size_t *count) {
  return fields_of(blob, (size_t)Moonbit_array_length(blob), count);
}

static outq *queue_new(qconn *q, int64_t stream) {
  outq *o = calloc(1, sizeof *o);
  if (!o) return NULL;
  o->stream = stream;
  o->next = q->queues;
  q->queues = o;
  return o;
}

// Opens a request stream: its id, or a negative error (no stream allowed
// yet or any more, or the handshake is not done).
MOONBIT_FFI_EXPORT int64_t mttp_ng_h3_submit_request(qconn_box *b,
                                                     moonbit_bytes_t blob,
                                                     int32_t body) {
  qconn *q = b->q;
  if (!q || !q->h3 || q->closed) return NGHTTP3_ERR_INVALID_STATE;
  int64_t stream;
  int rv = ngtcp2_conn_open_bidi_stream(q->conn, &stream, NULL);
  if (rv != 0) return rv;
  // From here a failure leaves an open stream, which would hold one of
  // the server's stream slots: it is reset both ways.
  size_t n;
  nghttp3_nv *nva = fields(blob, &n);
  if (!nva) {
    ngtcp2_conn_shutdown_stream(q->conn, 0, stream, NGHTTP3_H3_REQUEST_CANCELLED);
    return NGHTTP3_ERR_INVALID_ARGUMENT;
  }
  nghttp3_data_reader dr = {h3_read_data_cb};
  if (body && !queue_new(q, stream)) {
    free(nva);
    ngtcp2_conn_shutdown_stream(q->conn, 0, stream, NGHTTP3_H3_REQUEST_CANCELLED);
    return NGHTTP3_ERR_NOMEM;
  }
  rv = nghttp3_conn_submit_request(q->h3, stream, nva, n, body ? &dr : NULL,
                                   NULL);
  free(nva);
  if (rv != 0) {
    queue_remove(q, stream);
    ngtcp2_conn_shutdown_stream(q->conn, 0, stream, NGHTTP3_H3_REQUEST_CANCELLED);
    return rv;
  }
  return stream;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_submit_response(qconn_box *b,
                                                      int64_t stream,
                                                      moonbit_bytes_t blob,
                                                      int32_t body) {
  qconn *q = b->q;
  if (!q || !q->h3 || q->closed) return NGHTTP3_ERR_INVALID_STATE;
  size_t n;
  nghttp3_nv *nva = fields(blob, &n);
  if (!nva) return NGHTTP3_ERR_INVALID_ARGUMENT;
  nghttp3_data_reader dr = {h3_read_data_cb};
  if (body && !queue_new(q, stream)) {
    free(nva);
    return NGHTTP3_ERR_NOMEM;
  }
  int rv = nghttp3_conn_submit_response(q->h3, stream, nva, n,
                                        body ? &dr : NULL);
  free(nva);
  if (rv != 0) queue_remove(q, stream);
  return rv;
}

// Submits an informational (1xx) head on `stream`, before its response: 0
// or a negative nghttp3 error.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_submit_info(qconn_box *b, int64_t stream,
                                                  moonbit_bytes_t blob) {
  qconn *q = b->q;
  if (!q || !q->h3 || q->closed) return NGHTTP3_ERR_INVALID_STATE;
  size_t n;
  nghttp3_nv *nva = fields(blob, &n);
  if (!nva) return NGHTTP3_ERR_INVALID_ARGUMENT;
  int rv = nghttp3_conn_submit_info(q->h3, stream, nva, n);
  free(nva);
  return rv;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_push(qconn_box *b, int64_t stream,
                                           moonbit_bytes_t data, int32_t end) {
  qconn *q = b->q;
  if (!q || !q->h3 || q->closed) return -1;
  outq *o = queue_of(q, stream);
  if (!o || o->ended) return -1;
  int32_t len = Moonbit_array_length(data);
  if (len > 0) {
    chunk *c = calloc(1, sizeof *c);
    if (!c) return -1;
    c->data = malloc((size_t)len);
    if (!c->data) {
      free(c);
      return -1;
    }
    memcpy(c->data, data, (size_t)len);
    c->len = (size_t)len;
    if (o->tail) {
      o->tail->next = c;
    } else {
      o->head = c;
    }
    o->tail = c;
    o->queued += (size_t)len;
  }
  if (end) o->ended = 1;
  o->drained = 0;
  nghttp3_conn_resume_stream(q->h3, stream);
  return 0;
}

// Ends `stream`'s body after what was pushed with the trailer section in
// the field blob `blob`: 0, or -1 when the stream has no queue or its body
// already ended.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_end_with_trailers(qconn_box *b,
                                                        int64_t stream,
                                                        moonbit_bytes_t blob) {
  qconn *q = b->q;
  if (!q || !q->h3 || q->closed) return -1;
  outq *o = queue_of(q, stream);
  if (!o || o->ended) return -1;
  size_t len = (size_t)Moonbit_array_length(blob);
  o->trailers = malloc(len ? len : 1);
  if (!o->trailers) return -1;
  memcpy(o->trailers, blob, len);
  o->trailers_len = len;
  o->ended = 1;
  o->drained = 0;
  nghttp3_conn_resume_stream(q->h3, stream);
  return 0;
}

MOONBIT_FFI_EXPORT int64_t mttp_ng_h3_queued(qconn_box *b, int64_t stream) {
  if (!b->q) return -1;
  outq *o = queue_of(b->q, stream);
  return o ? (int64_t)o->queued : -1;
}

// The body bytes `stream`'s queue holds, sent or not, until the peer
// acknowledges them, or -1 without one: for the test that bounds it
// (connection_wbtest.mbt).
MOONBIT_FFI_EXPORT int64_t mttp_ng_h3_queue_held(qconn_box *b,
                                                 int64_t stream) {
  if (!b->q) return -1;
  outq *o = queue_of(b->q, stream);
  if (!o) return -1;
  int64_t held = 0;
  for (chunk *c = o->head; c; c = c->next) held += (int64_t)(c->len - c->acked);
  return held;
}

// Ends `stream` both ways with `code` (H3_REQUEST_CANCELLED for a client
// giving up, H3_NO_ERROR for a server that will not read on).
MOONBIT_FFI_EXPORT void mttp_ng_h3_reset(qconn_box *b, int64_t stream,
                                         int64_t code, int32_t read_only) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed) return;
  if (q->h3) nghttp3_conn_shutdown_stream_read(q->h3, stream);
  if (read_only) {
    ngtcp2_conn_shutdown_stream_read(q->conn, 0, stream, (uint64_t)code);
  } else {
    ngtcp2_conn_shutdown_stream(q->conn, 0, stream, (uint64_t)code);
  }
}

// Acknowledges `len` body bytes of `stream` that MoonBit took.
MOONBIT_FFI_EXPORT void mttp_ng_h3_consume(qconn_box *b, int64_t stream,
                                           int64_t len) {
  qconn *q = b->q;
  if (!q || !q->conn || q->closed || len <= 0) return;
  extend_offsets(q, stream, (size_t)len);
}

// A server's GOAWAY: the notice first, then the real last stream.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_shutdown(qconn_box *b, int32_t notice) {
  qconn *q = b->q;
  if (!q || !q->h3 || q->closed) return NGHTTP3_ERR_INVALID_STATE;
  return notice ? nghttp3_conn_submit_shutdown_notice(q->h3)
                : nghttp3_conn_shutdown(q->h3);
}

// The application error code of the connection's close, for events.
// --- a server's packets for no connection ----------------------------------

static moonbit_bytes_t copy_out(const uint8_t *data, size_t len) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) memcpy(out, data, len);
  return out;
}

// The Destination Connection ID of the first packet in `data`, reading a
// short header's as SERVER_CIDLEN long; empty when there is none to read.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_dcid(moonbit_bytes_t data) {
  ngtcp2_version_cid vc;
  int rv = ngtcp2_pkt_decode_version_cid(
      &vc, data, (size_t)Moonbit_array_length(data), SERVER_CIDLEN);
  if ((rv != 0 && rv != NGTCP2_ERR_VERSION_NEGOTIATION) || vc.dcidlen == 0)
    return moonbit_make_bytes(0, 0);
  return copy_out(vc.dcid, vc.dcidlen);
}

// A Stateless Reset (RFC 9000, section 10.3) for the short header packet
// `data`, whose DCID is no connection's: the client learns at once that the
// connection is gone (this server forgot it, or restarted) instead of
// waiting out its idle timeout. One byte shorter than `data` up to 43
// bytes, so that two endpoints cannot answer each other's resets for ever;
// empty for a long header packet, or one too short to answer.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_stateless_reset(
    moonbit_bytes_t data, moonbit_bytes_t keys) {
  size_t len = (size_t)Moonbit_array_length(data);
  if (Moonbit_array_length(keys) != SERVER_KEYS_BYTES ||
      len < 1 + SERVER_CIDLEN || (data[0] & 0x80))
    return moonbit_make_bytes(0, 0);
  // The random bytes include the first, so a reset is at least 21 bytes.
  size_t total = len <= 43 ? len - 1 : 43;
  if (total < NGTCP2_MIN_STATELESS_RESET_RANDLEN + NGTCP2_STATELESS_RESET_TOKENLEN)
    return moonbit_make_bytes(0, 0);
  size_t randlen = total - NGTCP2_STATELESS_RESET_TOKENLEN;
  ngtcp2_cid cid;
  ngtcp2_cid_init(&cid, data + 1, SERVER_CIDLEN);
  uint8_t token[NGTCP2_STATELESS_RESET_TOKENLEN];
  if (ngtcp2_crypto_generate_stateless_reset_token(
          token, keys, KEY_BYTES, &cid) != 0)
    return moonbit_make_bytes(0, 0);
  uint8_t random[64];
  if (RAND_bytes(random, (int)randlen) != 1) return moonbit_make_bytes(0, 0);
  uint8_t buf[64];
#if NGTCP2_VERSION_NUM >= 0x011600
  ngtcp2_stateless_reset_token t;
  memcpy(t.data, token, sizeof token);
  ngtcp2_ssize n =
      ngtcp2_pkt_write_stateless_reset2(buf, sizeof buf, &t, random, randlen);
#else
  ngtcp2_ssize n =
      ngtcp2_pkt_write_stateless_reset(buf, sizeof buf, token, random, randlen);
#endif
  if (n <= 0) return moonbit_make_bytes(0, 0);
  return copy_out(buf, (size_t)n);
}

// What a server answers the client Initial `data` from `remote_b` with
// instead of a connection: a Retry when `validate` and the Initial carries
// no valid Retry token, so that the client proves it receives at its
// address before the server keeps state for it (RFC 9000, section 8.1.2);
// and CONNECTION_CLOSE with INVALID_TOKEN when it carries a Retry token that
// is not valid (expired, or for another address), as section 8.1.3 says.
// Both are smaller than the Initial. Empty: start the connection.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_answer_initial(
    moonbit_bytes_t data, moonbit_bytes_t remote_b, int32_t validate,
    moonbit_bytes_t keys) {
  ngtcp2_pkt_hd hd;
  struct sockaddr_storage remote;
  if (Moonbit_array_length(keys) != SERVER_KEYS_BYTES)
    return moonbit_make_bytes(0, 0);
  const uint8_t *retry_key = keys + KEY_BYTES;
  char *text = c_string(remote_b);
  int ok = ensure_init() == 0 && text && parse_addr(text, &remote) == 0 &&
           ngtcp2_accept(&hd, data, (size_t)Moonbit_array_length(data)) == 0;
  free(text);
  if (!ok) return moonbit_make_bytes(0, 0);
  uint8_t buf[MAX_DATAGRAM];
  ngtcp2_ssize n;
  if (hd.tokenlen > 0 && hd.token[0] == NGTCP2_CRYPTO_TOKEN_MAGIC_RETRY) {
    ngtcp2_cid odcid;
    if (ngtcp2_crypto_verify_retry_token(
            &odcid, hd.token, hd.tokenlen, retry_key, KEY_BYTES,
            hd.version, (ngtcp2_sockaddr *)&remote, addr_len(&remote),
            &hd.dcid, RETRY_TOKEN_TIMEOUT, now_ns()) == 0)
      return moonbit_make_bytes(0, 0);
    n = ngtcp2_crypto_write_connection_close(buf, sizeof buf, hd.version,
                                             &hd.scid, &hd.dcid,
                                             NGTCP2_INVALID_TOKEN, NULL, 0);
  } else if (validate) {
    ngtcp2_cid scid;
    scid.datalen = SERVER_CIDLEN;
    if (RAND_bytes(scid.data, (int)scid.datalen) != 1)
      return moonbit_make_bytes(0, 0);
    uint8_t token[NGTCP2_CRYPTO_MAX_RETRY_TOKENLEN];
    ngtcp2_ssize tokenlen = ngtcp2_crypto_generate_retry_token(
        token, retry_key, KEY_BYTES, hd.version,
        (ngtcp2_sockaddr *)&remote, addr_len(&remote), &scid, &hd.dcid,
        now_ns());
    if (tokenlen < 0) return moonbit_make_bytes(0, 0);
    n = ngtcp2_crypto_write_retry(buf, sizeof buf, hd.version, &hd.scid, &scid,
                                  &hd.dcid, token, (size_t)tokenlen);
  } else {
    return moonbit_make_bytes(0, 0);
  }
  if (n <= 0) return moonbit_make_bytes(0, 0);
  return copy_out(buf, (size_t)n);
}

// --- 0-RTT --------------------------------------------------------------------

// The client's latest ticket and the server's transport parameters, for a
// later connection's `resume`: the ticket's length in four bytes, the
// ticket, the parameters. Empty before a ticket came.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_resumption(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->ticket) return moonbit_make_bytes(0, 0);
  size_t n = 4 + q->ticket_len + q->tp_len;
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  out[0] = (uint8_t)(q->ticket_len >> 24);
  out[1] = (uint8_t)(q->ticket_len >> 16);
  out[2] = (uint8_t)(q->ticket_len >> 8);
  out[3] = (uint8_t)q->ticket_len;
  memcpy(out + 4, q->ticket, q->ticket_len);
  memcpy(out + 4 + q->ticket_len, q->tp, q->tp_len);
  return out;
}

// 1 while a client may send requests in 0-RTT: it resumed with early data,
// the handshake has not completed, and the server has not rejected it.
MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_early(qconn_box *b) {
  qconn *q = b->q;
  return q && q->conn && !q->closed && q->early && !q->handshake &&
         !q->early_rejected;
}

// --- a connection's identity and end ---------------------------------------

// The connection IDs this end issued and has not retired, each after its
// length in one byte: the DCIDs the peer's packets carry, besides the one
// of its first Initial.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_scids(qconn_box *b) {
  qconn *q = b->q;
  buffer out = {0};
  if (q && q->conn) {
    size_t n = conn_scids(q->conn, NULL);
    ngtcp2_cid *cids = n ? calloc(n, sizeof *cids) : NULL;
    if (cids) {
      n = conn_scids(q->conn, cids);
      for (size_t i = 0; i < n; ++i) {
        put_u8(&out, (uint8_t)cids[i].datalen);
        buffer_put(&out, cids[i].data, cids[i].datalen);
      }
      free(cids);
    }
  }
  moonbit_bytes_t result = take_buffer(&out);
  free(out.data);
  return result;
}

// The connection's remote address now, as `parse_addr` reads it.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_remote(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->conn) return moonbit_make_bytes(0, 0);
  char text[64];
  size_t n = format_addr(&conn_path(q->conn)->remote, text);
  return copy_out((const uint8_t *)text, n);
}

// The CONNECTION_CLOSE this end sent, empty when it sent none (the peer
// closed, or the connection timed out).
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_close_datagram(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->close_pkt) return moonbit_make_bytes(0, 0);
  return copy_out(q->close_pkt, q->close_len);
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_closed_by_peer(qconn_box *b) {
  return b->q && b->q->closed && b->q->by_peer;
}

// The connection's probe timeout in milliseconds, at least 1.
MOONBIT_FFI_EXPORT int64_t mttp_ng_h3_pto_ms(qconn_box *b) {
  qconn *q = b->q;
  if (!q || !q->conn) return 1;
  int64_t ms = (int64_t)(conn_pto(q->conn) / NGTCP2_MILLISECONDS);
  return ms > 0 ? ms : 1;
}

// Sends `data` on the connected socket `fd` without waiting, for a client
// that closes a connection synchronously: 0, or -1 when the socket could
// not take it at once (then it is dropped, as the network may drop it).
MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_send_now(int32_t fd, moonbit_bytes_t data) {
  return send(fd, data, (size_t)Moonbit_array_length(data), MSG_DONTWAIT) < 0
             ? -1
             : 0;
}

// Fresh random keys for one listener (`ServerKeys::new`); empty when the
// system's random source fails.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_new_keys(void) {
  uint8_t keys[SERVER_KEYS_BYTES];
  if (RAND_bytes(keys, sizeof keys) != 1) return moonbit_make_bytes(0, 0);
  return copy_out(keys, sizeof keys);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_h3_strerror(int32_t code) {
  return to_bytes(code > -200 ? ngtcp2_strerror(code) : nghttp3_strerror(code));
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_ngtcp2_version(void) {
  return ngtcp2_version(0)->version_num;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_nghttp3_version(void) {
  return nghttp3_version(0)->version_num;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_crypto_init(void) { return ensure_init(); }
