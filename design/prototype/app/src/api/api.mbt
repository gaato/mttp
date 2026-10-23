///|
pub(all) struct User {
  id : Int
  name : String
} derive(Eq, Debug)

///|
pub let user_json : @schema.JsonCodec[User] = @schema.object2(
  "User",
  @schema.field("id", @schema.jint, (u : User) => u.id),
  @schema.field("name", @schema.jstring, (u : User) => u.name),
  (id, name) => { id, name },
)

///|
pub(all) struct Team {
  name : String
  lead : User
} derive(Eq, Debug)

///|
/// Nested named schema: Team references User by $ref (SC-01).
pub let team_json : @schema.JsonCodec[Team] = @schema.object2(
  "Team",
  @schema.field("name", @schema.jstring, (t : Team) => t.name),
  @schema.field("lead", user_json, (t : Team) => t.lead),
  (name, lead) => { name, lead },
)

///|
pub(all) struct Tree {
  label : String
  children : Array[Tree]
} derive(Eq, Debug)

///|
/// Recursive type: the schema is a $ref to itself (SC-01).
pub let tree_json : @schema.JsonCodec[Tree] = @schema.recursive("Tree", self_ => @schema.object2(
  "Tree",
  @schema.field("label", @schema.jstring, (t : Tree) => t.label),
  @schema.field("children", @schema.array(self_), (t : Tree) => t.children),
  (label, children) => { label, children },
))

///|
pub(all) struct GetUser {
  id : Int
  fields : String?
} derive(Eq, Debug)

///|
pub(all) struct NewUser {
  name : String
} derive(Eq, Debug)

///|
pub let new_user_json : @schema.JsonCodec[NewUser] = @schema.object2(
  "NewUser",
  @schema.field("name", @schema.jstring, (u : NewUser) => u.name),
  @schema.field("name", @schema.jstring, (u : NewUser) => u.name),
  (name, _) => { name, },
)

///|
pub(all) suberror ApiError {
  NotFound(Int)
  Forbidden
  NoTeam(String)
} derive(Debug)

///|
let api_errors : @endpoint.Errors[ApiError] = @endpoint.Errors::new(
  e => match e { ApiError::_ as a => Some(a); _ => None },
  [
    @endpoint.json_variant(404, @schema.jint.body()).contramap(e => match e { NotFound(id) => Some(id); _ => None }, id => NotFound(id)),
    // a second 404 with the same media type: the client tries both (SC-04)
    @endpoint.json_variant(404, @schema.jstring.body()).contramap(e => match e { NoTeam(n) => Some(n); _ => None }, n => NoTeam(n)),
    @endpoint.empty_variant(403).contramap(e => match e { Forbidden => Some(()); _ => None }, _ => Forbidden),
  ],
)

///|
pub let secured : @endpoint.Endpoint[String, Unit, ApiError, Unit] = @endpoint.endpoint
  .path("/api/v1").security(@endpoint.bearer()).errors(api_errors)

///|
pub let get_user : @endpoint.Endpoint[String, GetUser, ApiError, User] = secured
  .get("/users/{id}")
  .input(@endpoint.Input::map2(
    @endpoint.path("id", @schema.int.validate(@schema.minimum(1))),
    @endpoint.query("fields", @schema.string).optional(),
    (id, fields) => { id, fields }, g => (g.id, g.fields)))
  .output(@endpoint.json_out(user_json.body()))
  .operation_id("getUser")

///|
pub let get_team : @endpoint.Endpoint[String, String, ApiError, Team] = secured
  .get("/teams/{name}")
  .input(@endpoint.path("name", @schema.string))
  .output(@endpoint.json_out(team_json.body()))
  .operation_id("getTeam")

///|
/// 201 + Location: a header output (SC-03).
pub let create_user : @endpoint.Endpoint[String, NewUser, ApiError, (User, String)] = secured
  .post("/users")
  .input(@endpoint.body(new_user_json.body()))
  .output(@endpoint.json_out(user_json.body(), status=201).and_header("location", @schema.string))
  .operation_id("createUser")
  .max_body_bytes(64)

///|
pub let user_events : @endpoint.Endpoint[Unit, Unit, @endpoint.NoError, @endpoint.EventStream[User]] = @endpoint.endpoint
  .get("/api/v1/events")
  .output(@endpoint.sse_out(user_json))
  .operation_id("userEvents")

///|
pub let whoami : @endpoint.Endpoint[Unit, String?, @endpoint.NoError, Tree] = @endpoint.endpoint
  .get("/whoami")
  .input(@endpoint.attribute(@model.remote_addr))
  .output(@endpoint.json_out(tree_json.body()))

///|
/// Discord-style signed webhook: signature header + raw body checked
/// before the JSON body is decoded.
pub let webhook : @endpoint.Endpoint[(String, Bytes), NewUser, ApiError, Unit] = @endpoint.endpoint
  .post("/hooks/signed")
  .security(@endpoint.pair(@endpoint.signature_header("x-signature"), @endpoint.raw_body()))
  .input(@endpoint.body(new_user_json.body()))
  .errors(api_errors)
  .output(@endpoint.no_content())
