///|
pub async fn shutdown_before(
  addr : String,
  on_listen : (String) -> Unit,
) -> Unit {
  let listener = @http.Server(@socket.Addr::parse(addr))
  defer listener.close()
  on_listen(listener.addr.to_string())
  listener.run_forever(routing_before)
}
