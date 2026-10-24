///|
/// Both credentials are REQUIRED (map2 of two non-optional auth inputs).
test "two required auth inputs" {
  let both = @endpoint.Input::pair(@endpoint.bearer(scheme_name="userToken"), @endpoint.bearer(scheme_name="appToken"))
  let ep = @endpoint.endpoint(Get, "/me").security(both)
  let doc = @openapi.document([ep.doc()], title="t", version="1")
  guard doc is { "paths": { "/me": { "get": { "security": sec, .. }, .. }, .. }, .. } else { fail("no security") }
  // OpenAPI: [{A:[]},{B:[]}] means A OR B; [{A:[],B:[]}] means A AND B.
  inspect(sec.stringify(), content=(
    #|[{"userToken":[]},{"appToken":[]}]
  ))
}

///|
/// Optional auth: OpenAPI needs an empty requirement {} alternative.
test "optional auth input" {
  let ep = @endpoint.endpoint(Get, "/feed").security(@endpoint.bearer().optional())
  let doc = @openapi.document([ep.doc()], title="t", version="1")
  guard doc is { "paths": { "/feed": { "get": { "security": sec, .. }, .. }, .. }, .. } else { fail("no security") }
  inspect(sec.stringify(), content=(
    #|[{"bearer":[]}]
  ))
}

///|
pub(all) suberror ApiErr {
  NoUser(Int)
  NoRepo(String)
} derive(Debug)

///|
/// Two declared errors share 404 with different bodies (GitHub style).
test "two variants at one status" {
  let errs : @endpoint.Errors[ApiErr] = @endpoint.Errors::new(
    e => match e { ApiErr::_ as a => Some(a); _ => None },
    [
      @endpoint.json_variant(404, @schema.jint.body()).contramap(e => match e { NoUser(i) => Some(i); _ => None }, i => NoUser(i)),
      @endpoint.json_variant(404, @schema.jstring.body()).contramap(e => match e { NoRepo(s) => Some(s); _ => None }, s => NoRepo(s)),
    ],
  )
  let ep = @endpoint.endpoint(Get, "/x").errors(errs)
  let doc = @openapi.document([ep.doc()], title="t", version="1")
  guard doc is { "paths": { "/x": { "get": { "responses": { "404": r, .. }, .. }, .. }, .. }, .. } else { fail("no 404") }
  inspect(r.stringify(), content=(
    #|{"description":"","content":{"application/json":{"schema":{"type":"string"}}}}
  ))
}

///|
test "client decode of the second same-status variant" {
  let errs : @endpoint.Errors[ApiErr] = @endpoint.Errors::new(
    e => match e { ApiErr::_ as a => Some(a); _ => None },
    [
      @endpoint.json_variant(404, @schema.jint.body()).contramap(e => match e { NoUser(i) => Some(i); _ => None }, i => NoUser(i)),
      @endpoint.json_variant(404, @schema.jstring.body()).contramap(e => match e { NoRepo(s) => Some(s); _ => None }, s => NoRepo(s)),
    ],
  )
  let ep = @endpoint.endpoint(Get, "/x").errors(errs)
  let r = try { Ok(ep.decode_response({ status: @model.Status(404), headers: @model.Headers::new() }, b"\"gaato/mttp\"")) } catch { e => Err(e) }
  inspect(match r { Ok(Err(NoRepo(s))) => "declared NoRepo(\{s})"; Ok(Err(_)) => "declared other"; Ok(Ok(_)) => "ok"; Err(@client.Deserialization(_, message~, ..)) => "Deserialization: \{message}"; Err(_) => "other" }, content=(
    #|Deserialization: : expected integer
  ))
}
