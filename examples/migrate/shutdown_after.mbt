///|
pub async fn shutdown_after(
  addr : String,
  on_listen : (String) -> Unit,
) -> Unit {
  @server.serve(routing_after(), addr~, on_listen~)
}
