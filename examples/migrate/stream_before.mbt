///|
pub async fn stream_before(base : String) -> Int64 {
  let (_, conn) = @http.get_stream(base + "/stream")
  defer conn.close()
  let mut size = 0L
  while conn.read() is Some(chunk) {
    size += chunk.length().to_int64()
  }
  size
}
