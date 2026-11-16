///|
/// Re-exports the portable message, session, limits and error types.
pub using @core_ws {
  trait Session,
  type Message,
  type WsError,
  type WsErrorKind,
  type WsLimits,
  type CloseFrame,
  type CloseCode,
}

///|
/// Opens one WebSocket without redirects or retries. The default backend
/// uses system TLS trust and environment proxies; a supplied backend stays
/// caller-owned. Extensions are reserved: none are implemented at this stage.
/// JS hosts are a later stage and this function refuses on JS before I/O.
#cfg(not(target="js"))
pub async fn connect(
  url : String,
  backend? : &@mttp_core.Backend,
  subprotocols~ : Array[String] = [],
  extensions~ : Array[String] = [],
  origin? : String,
  headers? : @mttp_core.Headers,
  limits~ : @core_ws.WsLimits = @core_ws.WsLimits::default(),
) -> &@core_ws.Session raise @core_ws.WsError {
  if !extensions.is_empty() {
    raise @core_ws.WsError(
      kind=Handshake(status=0),
      detail="WebSocket extensions are not implemented yet",
    )
  }
  let key = @handshake.new_key(@env.rand)
  let request = @handshake.client_request(
    url,
    key~,
    subprotocols~,
    extensions~,
    origin?,
    headers?,
  )
  let request = {
    ..request,
    attributes: request.attributes.put(@client.redirect_limit, 0),
  }
  let own = backend is None
  let backend = backend.unwrap_or_else(() => @backend.AsyncBackend::new())
  defer (if own { backend.close() })
  let response = backend.send(request, {
    timeout_ms: Some(limits.send_timeout_ms),
    body: Stream(idle_ms=None),
  }) catch {
    error =>
      raise @core_ws.WsError(kind=Transport(error), detail=error.message())
  }
  defer response.close()
  errdefer @rt.close_unclaimed(response.attributes)
  // Take before validation so a failed handshake also closes the hand-over.
  let taken = match response.attributes.get(@rt.upgraded) {
    Some(upgrade) => upgrade.take_conn()
    None => None
  }
  let mut transferred = false
  defer (if !transferred && taken is Some((conn, _)) { conn.close() })
  let ready = response.attributes.get(@core_ws.ws_session)
  errdefer (if ready is Some(session) { session.abort() })
  let accepted = @handshake.check_server_response(
    response,
    key~,
    offered_subprotocols=subprotocols,
    offered_extensions=extensions,
  )
  if ready is Some(session) {
    return session
  }
  guard taken is Some((conn, pending)) else {
    raise @core_ws.WsError(
      kind=Handshake(status=response.status),
      detail="101 without an upgraded connection",
    )
  }
  let clock = @runtime.AsyncClock::new()
  let session = @core_ws.session_over_conn(
    conn,
    role=Client,
    pending~,
    clock~,
    timer=@runtime.ClockTimer::new(clock~),
    coordination=@runtime.RuntimeCoordination::new(),
    entropy=@env.rand,
    limits~,
    subprotocol?=accepted.subprotocol,
  )
  transferred = true
  session
}

///|
/// JS host WebSocket integration is reserved for the later host stage.
/// Keep the same async API on every target even though this refusal does no I/O.
#cfg(target="js")
#warnings("-unused_async")
pub async fn connect(
  url : String,
  backend? : &@mttp_core.Backend,
  subprotocols~ : Array[String] = [],
  extensions~ : Array[String] = [],
  origin? : String,
  headers? : @mttp_core.Headers,
  limits~ : @core_ws.WsLimits = @core_ws.WsLimits::default(),
) -> &@core_ws.Session raise @core_ws.WsError {
  ignore((url, backend, subprotocols, extensions, origin, headers, limits))
  raise @core_ws.WsError(
    kind=Handshake(status=0),
    detail="WebSocket connect is not supported on JS yet",
  )
}
