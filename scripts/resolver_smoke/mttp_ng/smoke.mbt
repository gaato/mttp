///|
/// Calls into OpenSSL, nghttp2, ngtcp2 and nghttp3, so the consumer links
/// each through gaato/mttp_ng's build.js and loads it.
pub fn run() -> Unit {
  println(@tls.openssl_version())
  println(@h2.nghttp2_version())
  println(@h3.ngtcp2_version())
  println(@h3.nghttp3_version())
}
