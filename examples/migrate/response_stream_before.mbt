///|
async fn response_stream_before(conn : @http.ServerConnection) -> Unit {
  conn.send_response(200, "OK")
  conn.write(b"one\n")
  conn.flush_partial_data()
  conn.write(b"two\n")
}
