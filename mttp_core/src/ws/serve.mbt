///|
/// Runs a server handler with shutdown monitoring on injected ports. Polling
/// costs at most 250 ms; Close itself has the session's close_timeout_ms bound.
/// No child outlives this call, including after cancellation or handler failure.
pub async fn serve_session(
  session : &Session,
  handler : async (&Session) -> Unit,
  stopping~ : () -> Bool,
  clock~ : &@rt.Clock,
  coordination~ : &@rt.Coordination,
) -> Unit noraise {
  defer session.abort()
  coordination.supervise(primary=() => handler(session) catch { _ => () }, monitor=() => {
    while !stopping() {
      clock.sleep(250)
    }
    session.close({ code: GoingAway, reason: "", })
    // Cancel a handler that is still waiting after Close has completed.
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Unknown,
      detail="server shutdown",
    )
  }) catch {
    _ => ()
  }
}
