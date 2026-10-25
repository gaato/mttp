///|
fn matches_template(
  doc : @endpoint.EndpointDoc,
  request : @model.Request,
) -> Bool {
  if doc.meth != Some(request.meth) {
    return false
  }
  let path = @model.Url::parse(request.url).path_segments() catch {
    _ => return false
  }
  let rest = doc.segments.last() is Some(Rest(_))
  if rest {
    if path.length() < doc.segments.length() - 1 {
      return false
    }
  } else if path.length() != doc.segments.length() {
    return false
  }
  for i, segment in doc.segments {
    if segment is Lit(text) && text != path[i] {
      return false
    }
  }
  true
}

///|
/// Adds a typed endpoint expectation to a stub. A one-endpoint router performs
/// real input decoding and response encoding, including declared errors.
/// Security inputs are decoded, but authentication is deliberately bypassed.
pub fn[S, I, E, O] when_endpoint(
  stub : @testing.BackendStub,
  endpoint : @endpoint.Endpoint[S, I, E, O],
  respond : async (I) -> O,
) -> @testing.BackendStub raise @endpoint.DefinitionError {
  let doc = endpoint.doc()
  let router = @router.Router::new([
    endpoint.serve(_ => (), (_, input) => respond(input)),
  ])
  stub.when(
    request => matches_template(doc, request),
    @testing.Factory((request, options) => router.send(request, options)),
  )
}

///|
/// Uses the same definition checker as Router and OpenAPI, returning both
/// fatal findings and nonfatal advisories without constructing an interpreter.
pub fn verify(
  docs : Array[@endpoint.EndpointDoc],
) -> Array[@endpoint.DefinitionProblem] {
  @endpoint.check_definitions(docs)
}
