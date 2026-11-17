///|
/// A JSON string returned by a path-parameter endpoint.
pub let hello : @endpoint.Endpoint[
  Unit,
  String,
  @endpoint.NoError,
  String,
  @client.Buffered,
] = @endpoint.endpoint
  .get("/hello/{name}")
  .input(@endpoint.path("name", @schema.string))
  .output(@endpoint.json_out(@schema.jstring.body()))
  .operation_id("hello")

///|
/// The same validation describes the request in OpenAPI and checks its body.
pub let echo : @endpoint.Endpoint[
  Unit,
  String,
  @endpoint.NoError,
  String,
  @client.Buffered,
] = @endpoint.endpoint
  .post("/echo")
  .input(
    @endpoint.body(
      @schema.jstring
      .validate(@schema.min_length(1))
      .validate(@schema.max_length(80))
      .body(),
    ),
  )
  .output(@endpoint.json_out(@schema.jstring.body()))
  .operation_id("echo")

///|
/// A bearer-protected endpoint with a typed authentication error.
pub let account : @endpoint.Endpoint[
  String,
  Unit,
  String,
  String,
  @client.Buffered,
] = @endpoint.endpoint
  .get("/account")
  .security(@endpoint.bearer())
  .errors(@endpoint.text_out(status=401))
  .output(@endpoint.json_out(@schema.jstring.body()))
  .operation_id("account")

///|
/// Generates the specification from the definitions used by server and client.
pub fn specification() -> @apispec.OpenApi raise {
  @openapi.to_openapi(
    [hello.doc(), echo.doc(), account.doc()],
    @apispec.Info::new("Example API", "1.0.0"),
  )
}

///|
/// Creates independent rate-limit state for each application instance.
pub fn application(token : String) -> @router.Router {
  let clock = @mttp.clock()
  @router.Router::must(
    [
      hello.serve_public(name => Ok("Hello, \{name}")),
      echo.serve_public(value => Ok(value)),
      account.serve(
        supplied => {
          if supplied == token {
            Ok(())
          } else {
            Err("Invalid bearer token")
          }
        },
        (_, _) => Ok("example account"),
      ),
      @openapi.docs_endpoint(try! specification()),
      @openapi.docs_ui_endpoint(spec_url="/openapi.json"),
    ],
    clock~,
    timer=@mttp.timer(),
    options={
      ..@router.ServerOptions::default(),
      max_body_bytes: 4096,
      middleware: [
        @router.secure_headers(),
        // One shared budget also bounds requests without a trusted peer address.
        @router.rate_limit(
          key=_ => Some("service"),
          limit=60,
          window_ms=60000,
          max_keys=1,
          clock~,
        ),
      ],
    },
  )
}
