///|
/// A validated 101 may carry a portable message handler. Server adapters
/// supply their own Session, keeping runtime ports out of endpoint definitions.
/// Engines consume this only after writing a successful handshake.
pub let server_handler : @mttp_core.AttributeKey[async (&Session) -> Unit] = @mttp_core.AttributeKey::new(
  "ws.server_handler",
)

///|
/// Converts a portable handler into the existing byte-connection hand-over.
/// Router and h1server supply their runtime ports; JS hosts use the handler
/// directly with a host Session. An explicitly supplied rt.upgrade wins.
pub fn prepare_upgrade(
  response : @mttp_core.Response,
  clock~ : &@rt.Clock,
  timer~ : &@rt.Timer,
  coordination~ : &@rt.Coordination,
) -> @mttp_core.Response {
  guard response.status == 101 &&
    response.attributes.get(@rt.upgrade) is None &&
    response.attributes.get(server_handler) is Some(handler) else {
    return response
  }
  {
    ..response,
    attributes: response.attributes.put(@rt.upgrade, (conn, pending, stopping) => {
      let session = session_over_conn(
        conn,
        role=Server,
        pending~,
        clock~,
        timer~,
        coordination~,
        entropy=_ => None,
        subprotocol?=response.headers.get("sec-websocket-protocol"),
      )
      serve_session(session, handler, stopping~, clock~, coordination~)
    }),
  }
}
