///|
struct User {
  id : Int
  name : String
} derive(FromJson, Debug)

///|
struct Fake {
  slept : Array[Int]
}

///|
impl @model.Clock for Fake with sleep(self, ms) {
  self.slept.push(ms)
}

///|
impl @model.Clock for Fake with now_unix_ms(_self) {
  0L
}

///|
struct Gh {
  max : Int
}

///|
/// A decider over decoded outcomes: retries 503, and a 200 whose body the
/// reader rejected as RATE_LIMITED (GitHub GraphQL style).
impl @client.RetryDecider for Gh with decide(self, e, ctx) {
  if ctx.attempt >= self.max {
    return Stop
  }
  match e {
    @client.UnexpectedStatus(head, ..) if head.status == 503 => RetryAfter(10)
    RateLimitedInBody => RetryAfter(1000)
    @model.TransportError(kind=Connect, ..) => RetryAfter(5)
    _ => Stop
  }
}

///|
suberror RateLimitedInBody

///|
test "retry loop sees reader errors; arrow-lambda wrapper; typed attribute" {
  let n = Ref::new(0)
  let seen_bucket : Ref[String?] = Ref::new(None)
  let stub = @client.from_fn((req, _opts) => {
    n.val += 1
    seen_bucket.val = req.attributes.get(@client.rate_limit_bucket)
    match n.val {
      1 => { status: 503, headers: [], body: Bytes(b"busy") }
      2 => { status: 200, headers: [], body: Bytes(b"{\"errors\":\"RATE_LIMITED\"}") }
      _ => { status: 200, headers: [], body: Bytes(b"{\"id\":1,\"name\":\"gaato\"}") }
    }
  })
  let backend = @client.with_header(stub, "x-trace", "1")
  let clock = Fake::{ slept: [] }
  let policy = @client.Policy::new(clock, Gh::{ max: 3 })
  let reader : @client.ResponseAs[User] = @client.as_bytes().map(b => {
    let j = @json.parse(@utf8.decode(b))
    if j is { "errors": _, .. } {
      raise RateLimitedInBody
    }
    @json.from_json(j)
  })
  let resp = @testing.run_sync(async fn() {
    @client.basic_request
    .get("https://api.example.com/graphql")
    .header("accept", "application/json")
    .attribute_bucket("graphql")
    .response(reader)
    .send(backend, policy~)
  })
  debug_inspect(resp.body, content="{ id: 1, name: \"gaato\" }")
  inspect(clock.slept, content="[10, 1000]")
  inspect(seen_bucket.val, content="Some(graphql)")
}
