///|
fn matches_template(doc : @endpoint.EndpointDoc, req : @model.Request) -> Bool {
  guard doc.meth == Some(req.meth) else { return false }
  let path = @model.Url::parse(req.url).path_segments() catch { _ => return false }
  guard path.length() == doc.segments.length() else { return false }
  for i, s in doc.segments {
    if s is Lit(l) && l != path[i] {
      return false
    }
  }
  true
}

///|
/// tapir whenEndpoint(..).thenRespond / thenRespondError: encoded through
/// the endpoint's own codecs by a one-endpoint Router. `respond` may raise
/// a declared error (classified as in serve) or anything else (500).
pub fn[S, I, E, O] when_endpoint(
  stub : @testing.BackendStub,
  ep : @endpoint.Endpoint[S, I, E, O],
  respond : async (I) -> O,
) -> @testing.BackendStub raise @endpoint.DefinitionError {
  let doc = ep.doc()
  let router = @router.Router::new([ep.serve(async fn(_) { () }, async fn(_, i) { respond(i) })])
  stub.when(req => matches_template(doc, req), async fn(req, opts) raise @model.TransportError {
    @client.Backend::send(router, req, opts)
  })
}

///|
/// tapir EndpointVerifier: the same checker Router::new uses.
pub fn verify(docs : Array[@endpoint.EndpointDoc]) -> Array[@endpoint.DefinitionProblem] {
  @endpoint.check_definitions(docs)
}
