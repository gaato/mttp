///|
/// Adapts the runtime's connect path for typed WsEndpoint.connect. A supplied
/// backend remains caller-owned. base_url prefixes the encoded endpoint path.
pub fn connector(
  base_url~ : String,
  backend? : &@mttp_core.Backend,
  limits~ : @core_ws.WsLimits = @core_ws.WsLimits::default(),
) -> @endpoint.WsConnector {
  (request, protocols) => {
    connect(
      @mttp_core.join_url(base_url, request.url),
      backend?,
      subprotocols=protocols,
      headers=request.headers,
      limits~,
    )
  }
}
