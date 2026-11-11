///|
fn matches_template(
  doc : @endpoint.EndpointDoc,
  request : @mttp.Request,
) -> Bool {
  if doc.meth != Some(request.meth) {
    return false
  }
  let path = @mttp.Url::parse(request.url).path_segments() catch {
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
/// Supply clock and timer ports when the tested Client sends timed requests.
pub fn[S, I, E, O, M] when_endpoint(
  stub : @testing.BackendStub,
  endpoint : @endpoint.Endpoint[S, I, E, O, M],
  respond : async (I) -> Result[O, E],
  clock? : &@rt.Clock,
  timer? : &@rt.Timer,
) -> @testing.BackendStub raise @endpoint.DefinitionError {
  let doc = endpoint.doc()
  let router = @router.Router::new(
    [endpoint.serve(_ => Ok(()), (_, input) => respond(input))],
    clock?,
    timer?,
  )
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
  adapter_max_body_bytes? : Int32,
) -> Array[@endpoint.DefinitionProblem] {
  @endpoint.check_definitions(docs, adapter_max_body_bytes?)
}
