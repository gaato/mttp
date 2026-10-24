// The endpoint-definition package: pure, all targets, imported by both the
// server and any client (native, js browser, wasm-gc).

///|
pub(all) struct User {
  id : Int
  name : String
} derive(Eq, Debug)

///|
/// Hand-written (or generated) codec: decoder, encoder and schema in one.
pub let user_json : @schema.JsonCodec[User] = @schema.object2(
  "User",
  @schema.field("id", @schema.jint, (u : User) => u.id),
  @schema.field("name", @schema.jstring, (u : User) => u.name),
  (id, name) => { id, name },
)

///|
/// A derive-based type with a generated `JsonSchema` impl.
pub(all) struct NewUser {
  name : String
} derive(ToJson, FromJson, Debug)

///|
pub impl @schema.JsonSchema for NewUser with json_schema(_) {
  @schema.Schema::of({
    "type": "object",
    "required": ["name"],
    "properties": { "name": { "type": "string", "maxLength": 64 } },
  }).named("NewUser")
}

///|
pub(all) suberror UserError {
  NotFound(Int)
  Forbidden
} derive(Debug)

///|
let user_errors : @endpoint.Errors[UserError] = @endpoint.Errors::new(
  e => match e {
    UserError::_ as u => Some(u)
    _ => None
  },
  [
    @endpoint.json_variant(
      404,
      @schema.jint.body(),
      description="no such user",
    ).contramap(u => match u { NotFound(id) => Some(id); _ => None }, id => NotFound(id)),
    @endpoint.empty_variant(403, description="forbidden").contramap(
      u => match u { Forbidden => Some(()); _ => None },
      _ => Forbidden,
    ),
  ],
)

///|
pub(all) struct GetUser {
  id : Int
  fields : String?
} derive(Eq, Debug)

///|
pub let get_user : @endpoint.Endpoint[String, GetUser, UserError, User] = @endpoint.endpoint(
  Get, "/users/{id}",
)
  .security(@endpoint.bearer())
  .input(
    @endpoint.Input::map2(
      @endpoint.path("id", @schema.int.validate(@schema.min(1))),
      @endpoint.query("fields", @schema.string).optional(),
      (id, fields) => { id, fields },
      g => (g.id, g.fields),
    ),
  )
  .errors(user_errors)
  .output(@endpoint.json_out(user_json.body()))
  .operation_id("getUser")
  .summary("Get a user")
  .tags(["users"])

///|
pub let create_user : @endpoint.Endpoint[String, NewUser, UserError, User] = @endpoint.endpoint(
  Post, "/users",
)
  .security(@endpoint.bearer())
  .input(@endpoint.body(@schema.json().body()))
  .errors(user_errors)
  .output(@endpoint.json_out(user_json.body(), status=201))
  .operation_id("createUser")
  .max_body(4096L)

///|
/// Discord-style webhook: the signature header is checked before the body
/// is read (missing -> 401, body untouched); the signature over the raw
/// body is checked before the JSON body is decoded.
pub let webhook : @endpoint.Endpoint[(String, Bytes), NewUser, UserError, Unit] = @endpoint.endpoint(
  Post, "/hooks/signed",
)
  .security(
    @endpoint.Input::pair(
      @endpoint.header("x-signature", @schema.string),
      @endpoint.raw_body(),
    ),
  )
  .input(@endpoint.body(@schema.json().body()))
  .errors(user_errors)
  .output(@endpoint.no_content())

///|
pub let user_events : @endpoint.Endpoint[Unit, Unit, @endpoint.NoError, @endpoint.EventSource[User]] = @endpoint.endpoint(
  Get, "/events",
).output(@endpoint.sse_out(user_json))

///|
pub let echo_ws : @endpoint.WsEndpoint[String, Unit, UserError, User, User] = @endpoint.endpoint(
  Get, "/ws",
)
  .security(@endpoint.bearer())
  .errors(user_errors)
  .websocket(@endpoint.ws_json(user_json), @endpoint.ws_json(user_json))

///|
/// Usable from wasm-gc (no async runtime): the host does the fetch.
pub fn browser_side(
  fetch : (@model.Request) -> (@model.ResponseHead, Bytes),
) -> String raise {
  let req = get_user.encode_request(@model.Uri::relative([]), "secret", {
    id: 1,
    fields: None,
  })
  let (head, bytes) = fetch(req)
  match get_user.decode_response(head, bytes) {
    Ok(u) => u.name
    Err(NotFound(id)) => "no user \{id}"
    Err(Forbidden) => "forbidden"
  }
}
