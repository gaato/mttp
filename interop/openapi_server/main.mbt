///|
struct Problem {
  type_ : String
  title : String
  status : Int32
}

///|
let problem_json : @schema.JsonCodec[Problem] = @schema.object3(
  "ApplicationProblem",
  @schema.field("type", @schema.jstring, problem => problem.type_),
  @schema.field("title", @schema.jstring, problem => problem.title),
  @schema.field("status", @schema.jint, problem => problem.status),
  (type_, title, status) => { type_, title, status, },
)

///|
let problem_body : @schema.BodyCodec[Problem] = {
  let json = problem_json.body()
  @schema.BodyCodec::new(
    "application/problem+json",
    bytes => json.decode(bytes),
    problem => json.encode(problem),
    json.schema(),
  )
}

///|
let widget_json : @schema.JsonCodec[(String, Int32)] = @schema.object2(
  "Widget",
  @schema.field(
    "name",
    @schema.jstring
    .validate(@schema.min_length(1))
    .validate(@schema.max_length(12)),
    widget => widget.0,
  ),
  @schema.field(
    "quantity",
    @schema.jint.validate(@schema.minimum(1)).validate(@schema.maximum(10)),
    widget => widget.1,
  ),
  (name, quantity) => (name, quantity),
)

///|
let item : @endpoint.Endpoint[
  Unit,
  (Int32, Int32, String, String),
  Problem,
  (String, Int32),
  @client.Buffered,
] = @endpoint.endpoint
  .get("/items/{id}")
  .input(
    @endpoint.Input::map4(
      @endpoint.path(
        "id",
        @schema.int.validate(@schema.minimum(1)).validate(@schema.maximum(3)),
      ),
      @endpoint.query(
        "page",
        @schema.int.validate(@schema.minimum(1)).validate(@schema.maximum(2)),
      ),
      @endpoint.header(
        "x-trace",
        @schema.string
        .validate(@schema.min_length(1))
        .validate(@schema.max_length(8)),
      ),
      @endpoint.cookie(
        "session",
        @schema.string
        .validate(@schema.min_length(1))
        .validate(@schema.max_length(8)),
      ),
      (id, page, trace, session) => (id, page, trace, session),
      value => value,
    ),
  )
  .errors(@endpoint.json_out(problem_body, status=404))
  .output(@endpoint.text_out().and_header("x-item-id", @schema.int))
  .operation_id("readItem")

///|
let create_widget : @endpoint.Endpoint[
  Unit,
  (String, Int32),
  Problem,
  ((String, Int32), String),
  @client.Buffered,
] = @endpoint.endpoint
  .post("/widgets")
  .input(@endpoint.body(widget_json.body()))
  .errors(@endpoint.json_out(problem_body, status=409))
  .output(
    @endpoint.json_out(widget_json.body(), status=201).and_header(
      "location", @schema.string,
    ),
  )
  .operation_id("createWidget")

///|
let secure : @endpoint.Endpoint[
  String,
  Unit,
  @endpoint.NoError,
  String,
  @client.Buffered,
] = @endpoint.endpoint
  .get("/secure")
  .security(@endpoint.bearer(scheme_name="bearerAuth"))
  .output(@endpoint.json_out(@schema.jstring.body()))
  .operation_id("readSecure")

///|
let events : @endpoint.Endpoint[
  Unit,
  Unit,
  @endpoint.NoError,
  @endpoint.EventStream[Int32],
  @client.Streaming,
] = @endpoint.endpoint
  .get("/events")
  .output(@endpoint.sse_out(@schema.jint))
  .operation_id("streamEvents")

///|
fn problem(status : Int32, title : String) -> Problem {
  { type_: "https://mttp.test/problems/\{status}", title, status, }
}

///|
fn main raise {
  let docs = [item.doc(), create_widget.doc(), secure.doc(), events.doc()]
  let spec = @openapi.to_openapi(
    docs,
    @apispec.Info::new("mttp Schemathesis interop", "1.0.0"),
    servers=[@apispec.Server::new("http://127.0.0.1:39040")],
  )
  if @env.args() is [_, "print"] {
    println(spec.to_json().stringify(indent=2))
    return
  }
  let app = @router.Router::must(
    [
      item.serve_public(input => {
        let (id, page, trace, session) = input
        if id == 3 {
          Err(problem(404, "item not found"))
        } else {
          Ok(("\{id}:\{page}:\{trace}:\{session}", id))
        }
      }),
      create_widget.serve_public(widget => {
        if widget.1 % 2 == 0 {
          Err(problem(409, "quantity conflicts"))
        } else {
          Ok((widget, "/widgets/\{widget.1}"))
        }
      }),
      secure.serve(token => Ok(token), (token, _) => Ok(token)),
      events.serve_public(_ => Ok(@endpoint.EventStream::from_array([1, 2]))),
      @openapi.docs_endpoint(spec),
    ],
    clock=@mttp.clock(),
    timer=@mttp.timer(),
  )
  @mttp.run(async fn() {
    let addr = match @env.args() {
      [_, addr] => addr
      _ => "127.0.0.1:39040"
    }
    @server.serve(app.handler(), addr~)
  })
}
