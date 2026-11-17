///|
async fn routing_before(
  request : @http.RequestHeader,
  conn : @http.ServerConnection,
) -> Unit {
  match (request.meth, request.path) {
    (Get, "/hello") => handler_before(conn)
    (Get, "/json") => {
      conn.send_response(200, "OK")
      conn.write(b"{\"name\":\"Ada\"}")
    }
    (Post, "/echo") => body_before(conn)
    (Get, "/stream") => response_stream_before(conn)
    _ => conn.send_response(404, "Not Found")
  }
}
