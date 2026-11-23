///|
/// Calls into OpenSSL and nghttp2 only, so the consumer of gaato/mttp_ng's
/// HTTP/2 packages links and loads them without ngtcp2 or nghttp3.
pub fn run() -> Unit {
  println(@tls.openssl_version())
  println(@h2.nghttp2_version())
}
