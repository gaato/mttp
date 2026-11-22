// gaato/mttp_ng/h3: QUIC and HTTP/3 on the system's ngtcp2 and nghttp3,
// without I/O.
#include <stdint.h>
#include <ngtcp2/ngtcp2.h>
#include <ngtcp2/ngtcp2_crypto_ossl.h>
#include <nghttp3/nghttp3.h>

#include "moonbit.h"

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_ngtcp2_version(void) {
  return ngtcp2_version(0)->version_num;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_nghttp3_version(void) {
  return nghttp3_version(0)->version_num;
}

MOONBIT_FFI_EXPORT int32_t mttp_ng_h3_crypto_init(void) {
  return ngtcp2_crypto_ossl_init();
}
