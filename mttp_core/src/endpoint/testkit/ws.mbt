///|
/// Pairs a typed client with a scripted raw peer. The raw side can inject
/// malformed payloads and inspect Close codes; the typed side runs the real
/// endpoint codecs. Like WebSocketStub, this is a message-level double;
/// use Router-as-Backend when a test needs wire bounds and backpressure.
pub fn[S, I, In, Out] websocket_pair(
  endpoint : @endpoint.WsEndpoint[S, I, In, Out],
  coordination~ : &@rt.Coordination,
  subprotocol? : String,
) -> (@endpoint.TypedSession[Out, In], &@ws.Session) raise @endpoint.DefinitionError {
  let problems = @endpoint.check_definitions([endpoint.doc()]).filter(p => {
    p.fatal
  })
  if !problems.is_empty() {
    raise @endpoint.DefinitionError(problems)
  }
  let (client, peer) = @sim.WebSocketStub::pair(coordination, subprotocol?)
  (endpoint.client_session(client), peer)
}
