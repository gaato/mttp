// Copyright 2026 International Digital Economy Academy
// Copyright 2026 Gakuto Furuya
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// A TLS server session for mttp's tests, over OpenSSL loaded at run time.
// The loading (dlopen of libssl, declared types, no OpenSSL headers) follows
// moonbitlang/core's runtime/openssl.c; changed from it: own symbol names,
// server only, and memory BIOs instead of BIOs that call back into MoonBit.
// The runtime keeps one process-wide BIO method for core's TLS client, so a
// server of our own must not touch it. Each call takes the ciphertext that
// arrived and room for the ciphertext to send, the same shape as moonrun's
// tls/connection host calls on wasm, so one MoonBit state machine drives
// both (engine.native.mbt, engine.wasm.mbt).

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <moonbit.h>

// The status of a handshake step, as moonrun's TlsState.
#define STATE_COMPLETED 0
#define STATE_WANT_READ 1
#define STATE_WANT_WRITE 2
#define STATE_ERROR 3
#define STATE_EOF 4

// What a plaintext read or write returns when it moved no data, as moonrun.
#define TLS_ERROR (-1)
#define TLS_CLOSED (-2)
#define TLS_WOULD_BLOCK (-3)

#define ERROR_CAPACITY 256

#ifdef _WIN32

// No Windows server: mttp's CI runs no Windows job, so the tests that need
// one are not built there (testtls.mbt says how to add one).
MOONBIT_EXPORT void *mttp_testtls_new(moonbit_bytes_t key, moonbit_bytes_t cert) {
  return 0;
}
MOONBIT_EXPORT int32_t mttp_testtls_is_null(void *self) { return self == 0; }
MOONBIT_EXPORT int32_t mttp_testtls_error(void *self, uint8_t *buf, int32_t len) {
  const char *message = "no TLS test server on Windows";
  int32_t n = (int32_t)strlen(message);
  if (n > len) n = len;
  memcpy(buf, message, n);
  return n;
}
MOONBIT_EXPORT int32_t mttp_testtls_accept(void *self, uint8_t *in, int32_t in_offset, int32_t in_len, uint8_t *out, int32_t out_offset, int32_t out_len) { return STATE_ERROR; }
MOONBIT_EXPORT int32_t mttp_testtls_read_plain(void *self, uint8_t *in, int32_t in_offset, int32_t in_len, uint8_t *out, int32_t out_offset, int32_t out_len, uint8_t *plain, int32_t plain_offset, int32_t plain_len) { return TLS_ERROR; }
MOONBIT_EXPORT int32_t mttp_testtls_write_plain(void *self, uint8_t *in, int32_t in_offset, int32_t in_len, uint8_t *out, int32_t out_offset, int32_t out_len, uint8_t *plain, int32_t plain_offset, int32_t plain_len) { return TLS_ERROR; }
MOONBIT_EXPORT int32_t mttp_testtls_drain(void *self, uint8_t *out, int32_t out_offset, int32_t out_len) { return 0; }
MOONBIT_EXPORT int32_t mttp_testtls_bytes_read(void *self) { return 0; }
MOONBIT_EXPORT int32_t mttp_testtls_bytes_to_write(void *self) { return 0; }
MOONBIT_EXPORT int32_t mttp_testtls_wants_write(void *self) { return 0; }
MOONBIT_EXPORT int32_t mttp_testtls_shutdown(void *self) { return TLS_ERROR; }
MOONBIT_EXPORT void mttp_testtls_free(void *self) {}

#else

#include <dlfcn.h>

typedef struct BIO BIO;
typedef struct BIO_METHOD BIO_METHOD;
typedef struct SSL SSL;
typedef struct SSL_CTX SSL_CTX;
typedef struct SSL_METHOD SSL_METHOD;

#define SSL_FILETYPE_PEM 1
#define SSL_ERROR_WANT_READ 2
#define SSL_ERROR_WANT_WRITE 3
#define SSL_ERROR_ZERO_RETURN 6

#define IMPORTED_FUNCTIONS\
  IMPORT_FUNC(const SSL_METHOD *, TLS_server_method, (void))\
  IMPORT_FUNC(SSL_CTX *, SSL_CTX_new, (const SSL_METHOD *method))\
  IMPORT_FUNC(void, SSL_CTX_free, (SSL_CTX *ctx))\
  IMPORT_FUNC(int, SSL_CTX_use_certificate_file, (SSL_CTX *ctx, const char *file, int type))\
  IMPORT_FUNC(int, SSL_CTX_use_PrivateKey_file, (SSL_CTX *ctx, const char *file, int type))\
  IMPORT_FUNC(SSL *, SSL_new, (SSL_CTX *ctx))\
  IMPORT_FUNC(void, SSL_free, (SSL *ssl))\
  IMPORT_FUNC(void, SSL_set_bio, (SSL *ssl, BIO *rbio, BIO *wbio))\
  IMPORT_FUNC(int, SSL_accept, (SSL *ssl))\
  IMPORT_FUNC(int, SSL_read, (SSL *ssl, void *buf, int num))\
  IMPORT_FUNC(int, SSL_write, (SSL *ssl, const void *buf, int num))\
  IMPORT_FUNC(int, SSL_shutdown, (SSL *ssl))\
  IMPORT_FUNC(int, SSL_get_error, (const SSL *ssl, int ret))\
  IMPORT_FUNC(const BIO_METHOD *, BIO_s_mem, (void))\
  IMPORT_FUNC(BIO *, BIO_new, (const BIO_METHOD *type))\
  IMPORT_FUNC(int, BIO_free, (BIO *bio))\
  IMPORT_FUNC(int, BIO_read, (BIO *bio, void *data, int len))\
  IMPORT_FUNC(int, BIO_write, (BIO *bio, const void *data, int len))\
  IMPORT_FUNC(size_t, BIO_ctrl_pending, (BIO *bio))\
  IMPORT_FUNC(unsigned long, ERR_get_error, (void))\
  IMPORT_FUNC(void, ERR_clear_error, (void))\
  IMPORT_FUNC(void, ERR_error_string_n, (unsigned long e, char *buf, size_t len))

#define IMPORT_FUNC(ret, name, params) static ret (*p_##name) params;
IMPORTED_FUNCTIONS
#undef IMPORT_FUNC

// Why loading failed, or 0 once it succeeded; kept for every later session.
static const char *load_failure = "OpenSSL not loaded yet";
static int loaded = 0;

// libssl's handle also finds the libcrypto symbols it depends on.
static void load_openssl(void) {
  if (loaded) return;
  loaded = 1;
  void *handle = dlopen("libssl.so.3", RTLD_LAZY | RTLD_LOCAL);
  if (!handle) handle = dlopen("libssl.so.1.1", RTLD_LAZY | RTLD_LOCAL);
  if (!handle) handle = dlopen("libssl.so", RTLD_LAZY | RTLD_LOCAL);
  if (!handle) {
    load_failure = "dlopen found no libssl (tried libssl.so.3, libssl.so.1.1, libssl.so)";
    return;
  }
#define IMPORT_FUNC(ret, name, params)\
  p_##name = (ret (*) params)dlsym(handle, #name);\
  if (!p_##name) {\
    load_failure = "libssl lacks " #name;\
    return;\
  }
  IMPORTED_FUNCTIONS
#undef IMPORT_FUNC
  load_failure = 0;
}

typedef struct {
  SSL_CTX *ctx;
  SSL *ssl;
  // Ciphertext that arrived, which SSL reads, and ciphertext SSL wrote,
  // which the caller takes out into its buffer.
  BIO *in;
  BIO *out;
  int32_t bytes_read;
  int32_t bytes_to_write;
  char error[ERROR_CAPACITY];
} session;

// Why the last session failed to start.
static char new_failure[ERROR_CAPACITY];

// OpenSSL's error queue is per thread and shared with core/async's TLS
// client in the same program, whose SSL_get_error reads it: every call here
// leaves it empty (record_error, or ERR_clear_error before returning), or a
// failure of this server would surface as a failure of the client.
static void record_error_kept(char *dst, const char *what);

static void record_error(char *dst, const char *what) {
  record_error_kept(dst, what);
  if (p_ERR_clear_error) p_ERR_clear_error();
}

static void record_error_kept(char *dst, const char *what) {
  unsigned long code = p_ERR_get_error ? p_ERR_get_error() : 0;
  if (code == 0) {
    strncpy(dst, what, ERROR_CAPACITY - 1);
    dst[ERROR_CAPACITY - 1] = 0;
    return;
  }
  char detail[ERROR_CAPACITY];
  p_ERR_error_string_n(code, detail, sizeof detail);
  size_t n = strlen(what);
  if (n > ERROR_CAPACITY / 2) n = ERROR_CAPACITY / 2;
  memcpy(dst, what, n);
  dst[n] = ':';
  dst[n + 1] = ' ';
  strncpy(dst + n + 2, detail, ERROR_CAPACITY - n - 3);
  dst[ERROR_CAPACITY - 1] = 0;
}

static void free_session(session *self) {
  if (self->ssl) {
    // SSL_free frees both BIOs, which SSL_set_bio gave it.
    p_SSL_free(self->ssl);
  } else {
    if (self->in) p_BIO_free(self->in);
    if (self->out) p_BIO_free(self->out);
  }
  if (self->ctx) p_SSL_CTX_free(self->ctx);
  free(self);
}

// `key` and `cert` are NUL-terminated paths to PEM files.
MOONBIT_EXPORT void *mttp_testtls_new(moonbit_bytes_t key, moonbit_bytes_t cert) {
  load_openssl();
  if (load_failure) {
    strncpy(new_failure, load_failure, ERROR_CAPACITY - 1);
    return 0;
  }
  p_ERR_clear_error();
  session *self = calloc(1, sizeof(session));
  if (!self) {
    strncpy(new_failure, "out of memory", ERROR_CAPACITY - 1);
    return 0;
  }
  self->ctx = p_SSL_CTX_new(p_TLS_server_method());
  if (!self->ctx) {
    record_error(new_failure, "SSL_CTX_new");
    free_session(self);
    return 0;
  }
  if (p_SSL_CTX_use_certificate_file(self->ctx, (const char *)cert, SSL_FILETYPE_PEM) != 1) {
    record_error(new_failure, "loading the certificate");
    free_session(self);
    return 0;
  }
  if (p_SSL_CTX_use_PrivateKey_file(self->ctx, (const char *)key, SSL_FILETYPE_PEM) != 1) {
    record_error(new_failure, "loading the private key");
    free_session(self);
    return 0;
  }
  self->in = p_BIO_new(p_BIO_s_mem());
  self->out = p_BIO_new(p_BIO_s_mem());
  self->ssl = self->in && self->out ? p_SSL_new(self->ctx) : 0;
  if (!self->ssl) {
    record_error(new_failure, "SSL_new");
    free_session(self);
    return 0;
  }
  p_SSL_set_bio(self->ssl, self->in, self->out);
  p_ERR_clear_error();
  return self;
}

MOONBIT_EXPORT int32_t mttp_testtls_is_null(void *self) { return self == 0; }

// Copies the session's last error, or why the last session failed to start
// when `self` is null, into `buf`; returns its length.
MOONBIT_EXPORT int32_t mttp_testtls_error(void *self, uint8_t *buf, int32_t len) {
  const char *message = self ? ((session *)self)->error : new_failure;
  int32_t n = (int32_t)strlen(message);
  if (n > len) n = len;
  memcpy(buf, message, n);
  return n;
}

// Hands SSL the ciphertext that arrived (a memory BIO takes all of it).
static void feed(session *self, uint8_t *in, int32_t in_offset, int32_t in_len) {
  self->bytes_read = 0;
  self->bytes_to_write = 0;
  if (in_len > 0) {
    int n = p_BIO_write(self->in, in + in_offset, in_len);
    self->bytes_read = n > 0 ? n : 0;
  }
}

// Moves what SSL wrote into the caller's buffer; the rest waits in the BIO
// (wants_write) for the next call.
static void take(session *self, uint8_t *out, int32_t out_offset, int32_t out_len) {
  if (out_len > 0 && p_BIO_ctrl_pending(self->out) > 0) {
    int n = p_BIO_read(self->out, out + out_offset, out_len);
    self->bytes_to_write += n > 0 ? n : 0;
  }
}

MOONBIT_EXPORT int32_t mttp_testtls_accept(
  void *handle, uint8_t *in, int32_t in_offset, int32_t in_len,
  uint8_t *out, int32_t out_offset, int32_t out_len
) {
  session *self = handle;
  feed(self, in, in_offset, in_len);
  p_ERR_clear_error();
  int ret = p_SSL_accept(self->ssl);
  int err = ret == 1 ? 0 : p_SSL_get_error(self->ssl, ret);
  if (err != 0 && err != SSL_ERROR_WANT_READ && err != SSL_ERROR_WANT_WRITE && err != SSL_ERROR_ZERO_RETURN) {
    record_error(self->error, "SSL_accept");
  }
  p_ERR_clear_error();
  take(self, out, out_offset, out_len);
  int pending = p_BIO_ctrl_pending(self->out) > 0;
  if (ret == 1) return pending ? STATE_WANT_WRITE : STATE_COMPLETED;
  switch (err) {
  case SSL_ERROR_WANT_READ:
    return pending ? STATE_WANT_WRITE : STATE_WANT_READ;
  case SSL_ERROR_WANT_WRITE:
    return STATE_WANT_WRITE;
  case SSL_ERROR_ZERO_RETURN:
    return STATE_EOF;
  default:
    return STATE_ERROR;
  }
}

// What a plaintext read or write that moved nothing returns.
static int32_t no_data(session *self, int ret, const char *what) {
  switch (p_SSL_get_error(self->ssl, ret)) {
  case SSL_ERROR_WANT_READ:
  case SSL_ERROR_WANT_WRITE:
    return TLS_WOULD_BLOCK;
  case SSL_ERROR_ZERO_RETURN:
    return TLS_CLOSED;
  default:
    record_error(self->error, what);
    return TLS_ERROR;
  }
}

MOONBIT_EXPORT int32_t mttp_testtls_read_plain(
  void *handle, uint8_t *in, int32_t in_offset, int32_t in_len,
  uint8_t *out, int32_t out_offset, int32_t out_len,
  uint8_t *plain, int32_t plain_offset, int32_t plain_len
) {
  session *self = handle;
  feed(self, in, in_offset, in_len);
  p_ERR_clear_error();
  int ret = p_SSL_read(self->ssl, plain + plain_offset, plain_len);
  int32_t result = ret > 0 ? ret : no_data(self, ret, "SSL_read");
  p_ERR_clear_error();
  take(self, out, out_offset, out_len);
  return result;
}

MOONBIT_EXPORT int32_t mttp_testtls_write_plain(
  void *handle, uint8_t *in, int32_t in_offset, int32_t in_len,
  uint8_t *out, int32_t out_offset, int32_t out_len,
  uint8_t *plain, int32_t plain_offset, int32_t plain_len
) {
  session *self = handle;
  feed(self, in, in_offset, in_len);
  p_ERR_clear_error();
  int ret = p_SSL_write(self->ssl, plain + plain_offset, plain_len);
  int32_t result = ret > 0 ? ret : no_data(self, ret, "SSL_write");
  p_ERR_clear_error();
  take(self, out, out_offset, out_len);
  return result;
}

// Moves ciphertext still waiting in the BIO into `out`.
MOONBIT_EXPORT int32_t mttp_testtls_drain(void *handle, uint8_t *out, int32_t out_offset, int32_t out_len) {
  session *self = handle;
  self->bytes_read = 0;
  self->bytes_to_write = 0;
  take(self, out, out_offset, out_len);
  return 0;
}

MOONBIT_EXPORT int32_t mttp_testtls_bytes_read(void *self) {
  return ((session *)self)->bytes_read;
}

MOONBIT_EXPORT int32_t mttp_testtls_bytes_to_write(void *self) {
  return ((session *)self)->bytes_to_write;
}

MOONBIT_EXPORT int32_t mttp_testtls_wants_write(void *self) {
  return p_BIO_ctrl_pending(((session *)self)->out) > 0;
}

// Queues close_notify; drain sends it. 0 on success.
MOONBIT_EXPORT int32_t mttp_testtls_shutdown(void *handle) {
  session *self = handle;
  p_ERR_clear_error();
  int ret = p_SSL_shutdown(self->ssl);
  if (ret >= 0) {
    p_ERR_clear_error();
    return 0;
  }
  record_error(self->error, "SSL_shutdown");
  return TLS_ERROR;
}

MOONBIT_EXPORT void mttp_testtls_free(void *self) {
  free_session(self);
}

#endif
