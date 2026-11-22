// gaato/mttp_ng/tls: TLS sessions over memory BIOs, on the system's OpenSSL.
//
// The C side holds no socket and never calls into MoonBit. MoonBit feeds the
// ciphertext it read from the connection beneath (`feed`), runs a step
// (`handshake`, `read`, `write`, `shutdown`) and takes the ciphertext the
// step produced (`take`) to write it beneath. Each step clears OpenSSL's
// error queue first: on Linux the runtime's own TLS (core/async/tls) loads
// the same libssl.so.3 into the process, so the queue is shared.
//
// Builds against OpenSSL 3.0 through 4.x, using no API deprecated there.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/bio.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include "moonbit.h"

// The result of a step, as tls.mbt's constants say.
#define STEP_DONE 0
#define STEP_WANT_READ 1
#define STEP_CLOSED 2
#define STEP_ERROR 3

#define ERROR_CAPACITY 512

// ---------------------------------------------------------------------------
// Contexts

// An SSL_CTX with the ALPN list a server chooses from, in wire form. The
// list lives beside the context, since the select callback reads it for as
// long as a session made from the context lives, and a session holds its
// own reference to the context (SSL_new), not to this struct.
typedef struct {
  SSL_CTX *ctx;
  unsigned char *alpn; // server only: its preference, in wire form
  size_t alpn_len;
  char error[ERROR_CAPACITY];
} context;

typedef struct {
  context *c;
} context_box;

static void context_free(context *c) {
  if (!c) return;
  if (c->ctx) SSL_CTX_free(c->ctx);
  free(c->alpn);
  free(c);
}

static void context_box_finalize(void *self) {
  context_box *b = self;
  context_free(b->c);
  b->c = NULL;
}

// The first error of OpenSSL's queue, or `fallback`.
static void record_error(char *out, const char *fallback) {
  unsigned long code = ERR_peek_last_error();
  if (code != 0) {
    ERR_error_string_n(code, out, ERROR_CAPACITY);
  } else {
    strncpy(out, fallback, ERROR_CAPACITY - 1);
    out[ERROR_CAPACITY - 1] = 0;
  }
  ERR_clear_error();
}

static moonbit_bytes_t to_bytes(const char *text) {
  int32_t n = (int32_t)strlen(text);
  moonbit_bytes_t b = moonbit_make_bytes(n, 0);
  memcpy(b, text, n);
  return b;
}

// A context box whose context is NULL carries no error text of its own, so
// a failure to create one keeps its text in a box that holds an empty
// context: `error` is read from it and `is_null` says the context failed.
static context_box *box_context(context *c) {
  context_box *b =
      moonbit_make_external_object(context_box_finalize, sizeof(context_box));
  b->c = c;
  return b;
}

static context *context_new(const SSL_METHOD *method) {
  context *c = calloc(1, sizeof *c);
  if (!c) return NULL;
  c->ctx = SSL_CTX_new(method);
  if (!c->ctx) {
    record_error(c->error, "SSL_CTX_new failed");
    return c;
  }
  // TLS 1.2 at least (RFC 9113, section 9.2, for HTTP/2); no renegotiation
  // and no compression, so a session's output comes from its own steps.
  SSL_CTX_set_min_proto_version(c->ctx, TLS1_2_VERSION);
  SSL_CTX_set_options(c->ctx, SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_COMPRESSION);
  SSL_CTX_set_mode(c->ctx, SSL_MODE_ENABLE_PARTIAL_WRITE |
                               SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
  return c;
}

static int context_failed(context *c) { return !c || !c->ctx; }

static void context_fail(context *c, const char *fallback) {
  record_error(c->error, fallback);
  SSL_CTX_free(c->ctx);
  c->ctx = NULL;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_tls_context_failed(context_box *b) {
  return context_failed(b->c);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_tls_context_error(context_box *b) {
  if (!b->c) return to_bytes("out of memory");
  return to_bytes(b->c->error);
}

// trust: 0 the system's roots, 1 no verification, 2 the roots of the PEM
// file at `path` only (no default directory beside it).
MOONBIT_FFI_EXPORT context_box *mttp_ng_tls_client_context(
    int32_t trust, moonbit_bytes_t path, moonbit_bytes_t alpn) {
  ERR_clear_error();
  context *c = context_new(TLS_client_method());
  if (context_failed(c)) return box_context(c);
  switch (trust) {
  case 0:
    SSL_CTX_set_verify(c->ctx, SSL_VERIFY_PEER, NULL);
    if (SSL_CTX_set_default_verify_paths(c->ctx) != 1) {
      context_fail(c, "cannot load the system's certificate roots");
      return box_context(c);
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
      return box_context(c);
    }
    memcpy(file, path, n);
    file[n] = 0;
    int ok = SSL_CTX_load_verify_file(c->ctx, file);
    free(file);
    if (ok != 1) {
      context_fail(c, "cannot load the PEM file of certificate roots");
      return box_context(c);
    }
  }
  }
  int32_t alpn_len = Moonbit_array_length(alpn);
  if (alpn_len > 0 &&
      SSL_CTX_set_alpn_protos(c->ctx, (const unsigned char *)alpn,
                              (unsigned int)alpn_len) != 0) {
    context_fail(c, "invalid ALPN list");
    return box_context(c);
  }
  return box_context(c);
}

static int select_alpn(SSL *ssl, const unsigned char **out,
                       unsigned char *outlen, const unsigned char *in,
                       unsigned int inlen, void *arg) {
  (void)ssl;
  context *c = arg;
  unsigned char *chosen = NULL;
  // The server's order decides (RFC 7301, section 3.2).
  if (SSL_select_next_proto(&chosen, outlen, c->alpn, (unsigned int)c->alpn_len,
                            in, inlen) != OPENSSL_NPN_NEGOTIATED) {
    // No protocol in common: go on without ALPN, so a client that offered
    // only something else reaches HTTP/1.1 rather than a handshake failure.
    return SSL_TLSEXT_ERR_NOACK;
  }
  *out = chosen;
  return SSL_TLSEXT_ERR_OK;
}

static BIO *memory_bio(const unsigned char *data, int32_t len) {
  return BIO_new_mem_buf(data, len);
}

// A server context from a PEM certificate chain (leaf first) and a PEM
// private key, choosing from `alpn` (wire form) in that order.
MOONBIT_FFI_EXPORT context_box *mttp_ng_tls_server_context(
    moonbit_bytes_t chain, moonbit_bytes_t key, moonbit_bytes_t alpn) {
  ERR_clear_error();
  context *c = context_new(TLS_server_method());
  if (context_failed(c)) return box_context(c);
  BIO *bio = memory_bio(chain, Moonbit_array_length(chain));
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
    // add1: the context takes its own reference.
    if (SSL_CTX_add1_chain_cert(c->ctx, extra) != 1) {
      X509_free(extra);
      BIO_free(bio);
      context_fail(c, "cannot add a certificate of the chain");
      return box_context(c);
    }
    X509_free(extra);
  }
  BIO_free(bio);
  // The end of the PEM data is an expected error of the last read.
  ERR_clear_error();
  bio = memory_bio(key, Moonbit_array_length(key));
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
  int32_t alpn_len = Moonbit_array_length(alpn);
  if (alpn_len > 0) {
    c->alpn = malloc((size_t)alpn_len);
    if (!c->alpn) {
      context_fail(c, "out of memory");
      return box_context(c);
    }
    memcpy(c->alpn, alpn, alpn_len);
    c->alpn_len = (size_t)alpn_len;
    SSL_CTX_set_alpn_select_cb(c->ctx, select_alpn, c);
  }
  // No session tickets: a resumed session would need a key that outlives
  // this context and its rotation; a full handshake is what h1server's TLS
  // costs too.
  SSL_CTX_set_num_tickets(c->ctx, 0);
  SSL_CTX_set_options(c->ctx, SSL_OP_NO_TICKET);
  return box_context(c);
}

// ---------------------------------------------------------------------------
// Sessions

typedef struct {
  SSL *ssl;
  BIO *in;  // ciphertext MoonBit fed; the session reads it
  BIO *out; // ciphertext the session wrote; MoonBit takes it
  char error[ERROR_CAPACITY];
} session;

typedef struct {
  session *s;
} session_box;

static void session_free(session *s) {
  if (!s) return;
  // SSL_free frees both BIOs, which SSL_set_bio handed to it.
  if (s->ssl) SSL_free(s->ssl);
  free(s);
}

static void session_box_finalize(void *self) {
  session_box *b = self;
  session_free(b->s);
  b->s = NULL;
}

static session_box *box_session(session *s) {
  session_box *b =
      moonbit_make_external_object(session_box_finalize, sizeof(session_box));
  b->s = s;
  return b;
}

static session *session_new(context_box *cb) {
  session *s = calloc(1, sizeof *s);
  if (!s) return NULL;
  if (context_failed(cb->c)) {
    strcpy(s->error, "the TLS context failed");
    return s;
  }
  s->ssl = SSL_new(cb->c->ctx);
  if (!s->ssl) {
    record_error(s->error, "SSL_new failed");
    return s;
  }
  s->in = BIO_new(BIO_s_mem());
  s->out = BIO_new(BIO_s_mem());
  if (!s->in || !s->out) {
    if (s->in) BIO_free(s->in);
    if (s->out) BIO_free(s->out);
    SSL_free(s->ssl);
    s->ssl = NULL;
    strcpy(s->error, "out of memory");
    return s;
  }
  // An empty input BIO says "retry", not EOF: MoonBit tracks the end of
  // the connection beneath itself.
  BIO_set_mem_eof_return(s->in, -1);
  SSL_set_bio(s->ssl, s->in, s->out);
  return s;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_tls_session_failed(session_box *b) {
  return !b->s || !b->s->ssl;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_tls_session_error(session_box *b) {
  if (!b->s) return to_bytes("out of memory");
  return to_bytes(b->s->error);
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

// A client session for `host` (a name, or an IP literal without brackets):
// SNI for a name (RFC 6066 forbids it for addresses) and the identity the
// certificate is checked against.
MOONBIT_FFI_EXPORT session_box *mttp_ng_tls_client_session(
    context_box *cb, moonbit_bytes_t host) {
  ERR_clear_error();
  session *s = session_new(cb);
  if (!s || !s->ssl) return box_session(s);
  int32_t n = Moonbit_array_length(host);
  char *name = malloc((size_t)n + 1);
  if (!name) {
    SSL_free(s->ssl);
    s->ssl = NULL;
    strcpy(s->error, "out of memory");
    return box_session(s);
  }
  memcpy(name, host, n);
  name[n] = 0;
  int ok;
  if (is_ip_literal(name)) {
    ok = X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(s->ssl), name) == 1;
  } else {
    ok = SSL_set_tlsext_host_name(s->ssl, name) == 1 &&
         SSL_set1_host(s->ssl, name) == 1;
  }
  free(name);
  if (!ok) {
    record_error(s->error, "invalid host name for TLS");
    SSL_free(s->ssl);
    s->ssl = NULL;
    return box_session(s);
  }
  SSL_set_connect_state(s->ssl);
  return box_session(s);
}

MOONBIT_FFI_EXPORT session_box *mttp_ng_tls_server_session(context_box *cb) {
  ERR_clear_error();
  session *s = session_new(cb);
  if (s && s->ssl) SSL_set_accept_state(s->ssl);
  return box_session(s);
}

// Hands `len` bytes of ciphertext from `data[offset..]` to the session.
MOONBIT_FFI_EXPORT int32_t mttp_ng_tls_feed(session_box *b, moonbit_bytes_t data,
                                            int32_t offset, int32_t len) {
  session *s = b->s;
  if (!s || !s->ssl || len <= 0) return 0;
  return BIO_write(s->in, data + offset, len) == len ? 0 : -1;
}

// How many bytes of ciphertext wait to be written beneath.
MOONBIT_FFI_EXPORT int32_t mttp_ng_tls_pending(session_box *b) {
  session *s = b->s;
  if (!s || !s->ssl) return 0;
  return (int32_t)BIO_ctrl_pending(s->out);
}

// Takes all the ciphertext waiting to be written beneath.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_tls_take(session_box *b) {
  session *s = b->s;
  int32_t n = (s && s->ssl) ? (int32_t)BIO_ctrl_pending(s->out) : 0;
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  if (n > 0) BIO_read(s->out, out, n);
  return out;
}

// The step's outcome from SSL_get_error, recording the error text.
static int32_t outcome(session *s, int ret) {
  int code = SSL_get_error(s->ssl, ret);
  switch (code) {
  case SSL_ERROR_WANT_READ:
    return STEP_WANT_READ;
  case SSL_ERROR_ZERO_RETURN:
    return STEP_CLOSED;
  default: {
    long verify = SSL_get_verify_result(s->ssl);
    if (verify != X509_V_OK) {
      snprintf(s->error, ERROR_CAPACITY, "certificate verify failed: %s",
               X509_verify_cert_error_string(verify));
      ERR_clear_error();
    } else {
      record_error(s->error, "TLS failure");
    }
    return STEP_ERROR;
  }
  }
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_tls_handshake(session_box *b) {
  session *s = b->s;
  if (!s || !s->ssl) return STEP_ERROR;
  ERR_clear_error();
  int ret = SSL_do_handshake(s->ssl);
  return ret == 1 ? STEP_DONE : outcome(s, ret);
}

// Decrypts at most `len` bytes into `out[offset..]`: the count read, or
// minus a STEP_ constant (WANT_READ, CLOSED for close_notify, ERROR).
MOONBIT_FFI_EXPORT int32_t mttp_ng_tls_read(session_box *b, uint8_t *out,
                                            int32_t offset, int32_t len) {
  session *s = b->s;
  if (!s || !s->ssl) return -STEP_ERROR;
  ERR_clear_error();
  int ret = SSL_read(s->ssl, out + offset, len);
  if (ret > 0) return ret;
  return -outcome(s, ret);
}

// Encrypts `len` bytes of `data[offset..]` into the output BIO: the count
// taken (all of it, since a memory BIO never fills), or minus a STEP_
// constant.
MOONBIT_FFI_EXPORT int32_t mttp_ng_tls_write(session_box *b,
                                             moonbit_bytes_t data,
                                             int32_t offset, int32_t len) {
  session *s = b->s;
  if (!s || !s->ssl) return -STEP_ERROR;
  if (len == 0) return 0;
  if (SSL_get_shutdown(s->ssl) & SSL_RECEIVED_SHUTDOWN) return -STEP_CLOSED;
  ERR_clear_error();
  int ret = SSL_write(s->ssl, data + offset, len);
  if (ret > 0) return ret;
  return -outcome(s, ret);
}

// Queues close_notify; MoonBit takes and writes it.
MOONBIT_FFI_EXPORT void mttp_ng_tls_shutdown(session_box *b) {
  session *s = b->s;
  if (!s || !s->ssl) return;
  ERR_clear_error();
  SSL_shutdown(s->ssl);
  ERR_clear_error();
}

// The ALPN protocol the handshake chose, or empty.
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_tls_alpn(session_box *b) {
  session *s = b->s;
  const unsigned char *data = NULL;
  unsigned int len = 0;
  if (s && s->ssl) SSL_get0_alpn_selected(s->ssl, &data, &len);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) memcpy(out, data, len);
  return out;
}

// The negotiated protocol version, as "TLSv1.3".
MOONBIT_FFI_EXPORT moonbit_bytes_t mttp_ng_tls_version(session_box *b) {
  session *s = b->s;
  return to_bytes(s && s->ssl ? SSL_get_version(s->ssl) : "");
}

// Frees the session now rather than when the box goes.
MOONBIT_FFI_EXPORT void mttp_ng_tls_free(session_box *b) {
  session_free(b->s);
  b->s = NULL;
}

MOONBIT_FFI_EXPORT int64_t mttp_ng_tls_openssl_version(void) {
  return (int64_t)OpenSSL_version_num();
}
