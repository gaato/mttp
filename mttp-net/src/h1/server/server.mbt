///|
/// Configuration and observation types shared by listener and connection servers.
pub using @config {type ServerLimits, type ServeError, type ServerConfigError}

///|
/// Serves an owned connection using explicit clock, deadline and coordination
/// ports. EOF in the peer's sending direction still permits the response.
/// The listener/supervisor owns background scheduling and stopping decisions.
pub async fn serve_conn(
  conn : &@connection.Conn,
  handler : @model.Handler,
  clock~ : &@clock.Clock,
  timer~ : &@clock.Timer,
  coordination~ : &@connection.Coordination,
  limits~ : ServerLimits = ServerLimits::default(),
  peer~ : String = "",
  authority~ : String = "localhost",
  on_error~ : (ServeError) -> Unit = _ => (),
  compression~ : Bool = false,
  stopping~ : () -> Bool = () => false,
  background? : (async () -> Unit) -> Unit,
) -> Unit {
  defer conn.close()
  limits.validate()
  let session = @engine.Connection::new(
    @engine.Wire::new(conn, clock~, timer~, coordination~),
  )
  @engine.exchange(
    session, peer, authority, handler, limits, stopping, on_error, compression, background,
  )
}
