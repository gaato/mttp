///|
async fn body_before(conn : @http.ServerConnection) -> Unit {
  let buffer = @buffer.Buffer()
  while conn.read() is Some(chunk) {
    if chunk.length() > 65536 - buffer.length() {
      conn.send_response(413, "Content Too Large")
      return
    }
    buffer.write_bytes(chunk)
  }
  conn.send_response(200, "OK")
  conn.write(buffer.to_bytes())
}
