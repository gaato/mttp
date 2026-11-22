///|
/// Calls into libcurl, so the consumer links it through gaato/mttp_curl's
/// build.js and loads it.
pub fn run() -> Unit {
  println(@mttp_curl.CurlBackend::libcurl_version())
}
