///|
#derive(Eq, Debug)
struct Signup {
  name : String
  count : Int32
  agree : Bool
  nickname : String?
  age : Int32?
  tags : Array[String]
}

///|
/// One definition shared by the form and the JSON endpoint.
let signup : @schema.JsonCodec[Signup] = @schema.object6(
  "Signup",
  @schema.field("name", @schema.jstring.validate(@schema.max_length(8)), (
    s : Signup,
  ) => s.name),
  @schema.field("count", @schema.jint, s => s.count),
  @schema.field("agree", @schema.jbool, s => s.agree),
  @schema.field("nickname", @schema.option(@schema.jstring), s => s.nickname),
  @schema.field("age", @schema.option(@schema.jint), s => s.age),
  @schema.field("tags", @schema.array(@schema.jstring), s => s.tags),
  (name, count, agree, nickname, age, tags) => {
    name,
    count,
    agree,
    nickname,
    age,
    tags,
  },
)

///|
let form_signup : @endpoint.Endpoint[
  Unit,
  Signup,
  @endpoint.NoError,
  Signup,
  @client.Buffered,
] = @endpoint.endpoint
  .post("/signup")
  .input(@endpoint.body(@schema.form_codec(signup)))
  .output(@endpoint.json_out(signup.body()))

///|
let json_signup : @endpoint.Endpoint[
  Unit,
  Signup,
  @endpoint.NoError,
  Signup,
  @client.Buffered,
] = @endpoint.endpoint
  .post("/signup.json")
  .input(@endpoint.body(signup.body()))
  .output(@endpoint.json_out(signup.body()))

///|
fn signup_router() -> @router.Router raise {
  @router.Router::new([
    form_signup.serve_public(s => Ok(s)),
    json_signup.serve_public(s => Ok(s)),
  ])
}

///|
/// The `(path, code, message)` of each issue in a 400 problem response.
fn problem_issues(
  response : @mttp.Response,
) -> Array[(String, String, String)] raise {
  assert_eq(response.status, 400)
  let body = @schema.jvalue.body().decode(response.body.as_bytes().unwrap())
  guard body is { "errors": Array(errors), .. } else { fail("no errors") }
  errors.map(e => {
    guard e
      is {
        "path": String(path),
        "code": String(code),
        "message": String(message),
        ..
      } else {
      return ("", "", e.stringify())
    }
    (path, code, message)
  })
}

///|
test "typed form bodies round trip through a router used as the backend" {
  let router = signup_router()
  let client = @client.Client::new(router, @sim.FakeClock::new())
  let full = {
    name: "ann",
    count: 3,
    agree: true,
    nickname: Some("a b&c"),
    age: Some(30),
    tags: ["x", "y"],
  }
  let minimal = {
    name: "",
    count: -1,
    agree: false,
    nickname: None,
    age: None,
    tags: [],
  }
  let raw = form_signup.request((), full).raw()
  assert_eq(
    raw.headers.get("content-type"),
    Some("application/x-www-form-urlencoded"),
  )
  assert_eq(
    raw.body,
    @mttp.Body::Bytes(
      b"name=ann&count=3&agree=true&nickname=a+b%26c&age=30&tags=x&tags=y",
    ),
  )
  @driver.run_sync(() => {
    for value in [full, minimal] {
      assert_eq(form_signup.call(client, (), value).unwrap().unwrap(), value)
    }
    // What a browser sends: a checkbox's default `on`, an unchecked box and
    // an empty checkbox group left out, a blank optional number input.
    let browser = router.dispatch(
      @mttp.Request::post("/signup").body_form([
        ("name", "bo"),
        ("count", "+07"),
        ("agree", "on"),
        ("age", ""),
        ("tags", "b"),
        ("tags", "a"),
      ]),
    )
    assert_eq(browser.status, 200)
    assert_eq(signup.body().decode(browser.body.as_bytes().unwrap()), {
      name: "bo",
      count: 7,
      agree: true,
      nickname: None,
      age: None,
      tags: ["b", "a"],
    })
    let unchecked = router.dispatch(
      @mttp.Request::post("/signup").body_form([("name", "bo"), ("count", "1")]),
    )
    assert_eq(signup.body().decode(unchecked.body.as_bytes().unwrap()), {
      name: "bo",
      count: 1,
      agree: false,
      nickname: None,
      age: None,
      tags: [],
    })
  })
  client.close()
}

///|
test "form and JSON bodies report invalid values at the same pointers" {
  let router = signup_router()
  @driver.run_sync(() => {
    let invalid = router.dispatch(
      @mttp.Request::post("/signup").body_form([
        ("name", "ann"),
        ("count", "three"),
      ]),
    )
    assert_eq(problem_issues(invalid), [("/count", "type", "expected integer")])
    let twice = router.dispatch(
      @mttp.Request::post("/signup").body_form([
        ("name", "ann"),
        ("count", "1"),
        ("count", "2"),
      ]),
    )
    assert_eq(problem_issues(twice), [
      ("/count", "multiple", "expected one value, got 2"),
    ])
    let long_name = "abcdefghij"
    let form = router.dispatch(
      @mttp.Request::post("/signup").body_form([
        ("name", long_name),
        ("count", "1"),
      ]),
    )
    let json = router.dispatch(
      @mttp.Request::post("/signup.json").body_json({
        "name": Json(long_name),
        "count": 1,
        "agree": false,
        "tags": [],
      }),
    )
    assert_eq(problem_issues(form), [("/name", "constraint", "longer than 8")])
    assert_eq(problem_issues(form), problem_issues(json))
  })
}

///|
test "typed form bodies are documented as urlencoded with the codec schema" {
  let spec = @openapi.to_openapi(
    [form_signup.doc()],
    @apispec.Info::new("Forms", "1"),
  )
  let body = spec.paths["/signup"].operations["post"].request_body.unwrap()
  assert_true(body.required)
  assert_eq(body.content.keys().collect(), ["application/x-www-form-urlencoded"])
  assert_eq(
    body.content["application/x-www-form-urlencoded"].schema,
    Some({ "$ref": "#/components/schemas/Signup" }),
  )
  assert_eq(spec.components.schemas.get("Signup"), Some(signup.schema().json))
}

///|
test "a form codec over a nested object is refused as a definition problem" {
  let nested = @schema.object2(
    "Order",
    @schema.field("id", @schema.jint, (o : (Int32, Int32)) => o.0),
    @schema.field(
      "item",
      @schema.object1("Item", @schema.field("n", @schema.jint, n => n), n => n),
      o => o.1,
    ),
    (id, item) => (id, item),
  )
  let ep = @endpoint.endpoint
    .post("/orders")
    .input(@endpoint.body(@schema.form_codec(nested)))
  let message = "form_codec property item is not a scalar or an array of scalars"
  assert_true(
    @endpoint.check_definitions([ep.doc()])
    .iter()
    .any(p => p.fatal && p.message.contains(message)),
  )
  try
    @openapi.to_openapi([ep.doc()], @apispec.Info::new("Forms", "1")) |> ignore
  catch {
    @endpoint.DefinitionError(problems) =>
      assert_true(problems.iter().any(p => p.message.contains(message)))
  } noraise {
    _ => fail("nested form codec documented")
  }
}
