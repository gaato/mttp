///|
/// Validates a WebSocket request and returns either its refusal or a 101
/// carrying the server hand-over. The first supported offered protocol wins.
/// The callback owns a bounded session; shutdown sends GoingAway and joins it.
pub fn upgrade(
  request : @mttp_core.Request,
  origins~ : @handshake.OriginPolicy = SameOrigin,
  subprotocols? : Array[String],
  limits~ : @core_ws.WsLimits = @core_ws.WsLimits::default(),
  handler~ : async (&@core_ws.Session) -> Unit,
) -> @mttp_core.Response {
  let offer = @handshake.check_client_request(request, origins~, subprotocols?) catch {
    @handshake.Refusal(status~, headers~, ..) =>
      return @mttp_core.Response::new(status, headers~)
  }
  let mut subprotocol = None
  for protocol in offer.subprotocols {
    if offer.supported_subprotocols.contains(protocol) {
      subprotocol = Some(protocol)
      break
    }
  }
  let response = offer.accept(subprotocol?) catch {
    _ => return @mttp_core.Response::new(500)
  }
  upgraded_response(response, limits, subprotocol, handler)
}

///|
#cfg(target="js")
fn upgraded_response(
  response : @mttp_core.Response,
  limits : @core_ws.WsLimits,
  subprotocol : String?,
  handler : async (&@core_ws.Session) -> Unit,
) -> @mttp_core.Response {
  @fetch.websocket_upgrade(response, limits, subprotocol, handler)
}

///|
#cfg(not(target="js"))
fn upgraded_response(
  response : @mttp_core.Response,
  limits : @core_ws.WsLimits,
  subprotocol : String?,
  handler : async (&@core_ws.Session) -> Unit,
) -> @mttp_core.Response {
  {
    ..response,
    attributes: response.attributes.put(@rt.upgrade, (conn, pending, stopping) => {
      let clock = @runtime.AsyncClock::new()
      let timer = @runtime.ClockTimer::new(clock~)
      let coordination = @runtime.RuntimeCoordination::new()
      let session = @core_ws.session_over_conn(
        conn,
        role=Server,
        pending~,
        clock~,
        timer~,
        coordination~,
        entropy=_ => None,
        limits~,
        subprotocol?,
      )
      @core_ws.serve_session(session, handler, stopping~, clock~, coordination~)
    }),
  }
}
