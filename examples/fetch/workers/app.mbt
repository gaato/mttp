///|
/// Routes by path. A Map built at module level hashes its keys while the
/// module is evaluated, which draws the hash seed from crypto.getRandomValues:
/// Workers allows that only inside a request, so entry.js imports this module
/// lazily through `workers(() => import(...))`.
let routes : Map[String, String] = {
  "/hello": "hello",
  "/notes": "notes",
  "/slow": "slow",
  "/slow/partial": "partial",
  "/slow/unread": "unread",
  "/reject": "reject",
}

///|
/// Notes stored by background work, kept for the isolate's lifetime.
let notes : Array[String] = []

///|
/// How many POST /slow requests have finished their background work.
let slow : Ref[Int32] = Ref(0)

///|
fn json(status : Int32, value : Json) -> @mttp_core.Response {
  @mttp_core.Response::new(
    status,
    headers=@mttp_core.Headers::empty().add("content-type", "application/json"),
    body=Bytes(@utf8.encode(value.stringify())),
  )
}

///|
fn optional(value : String?) -> Json {
  match value {
    Some(text) => Json::string(text)
    None => Json::null()
  }
}

///|
fn path_of(url : String) -> String {
  (@mttp_core.Url::parse(url) catch { _ => return "" }).path
}

///|
async fn route(request : @mttp_core.Request) -> @mttp_core.Response noraise {
  let env = request.attributes.get(@fetch.env)
  let binding = (key : String) => {
    match env {
      Some(env) => @fetch.env_string(env, key)
      None => None
    }
  }
  match (request.meth, routes.get(path_of(request.url))) {
    (Get, Some("hello")) =>
      json(200, {
        "greeting": optional(binding("GREETING")),
        "limits": optional(binding("LIMITS")),
        "missing": optional(binding("MISSING")),
      })
    (Post, Some("notes")) => {
      let bytes = match request.body {
        Stream(stream) =>
          @mttp_core.read_bounded(stream.take(), 1024) catch {
            _ => return json(400, { "error": "unreadable body" })
          }
        Bytes(bytes) => bytes
        _ => b""
      }
      let text = @utf8.decode_lossy(bytes)
      // Runs after the reply, kept alive by waitUntil.
      if request.attributes.get(@mttp_core.background) is Some(schedule) {
        schedule(() => notes.push(text))
      }
      json(202, { "queued": Json::string(text) })
    }
    // Answers, then keeps working after the reply, like a deferred Discord
    // interaction. "slow" reads the whole body, "partial" one piece of it and
    // "unread" none.
    (Post, Some("slow" | "partial" | "unread" as kind)) => {
      let bytes = match (kind, request.body) {
        ("unread", _) => b""
        ("slow", Stream(stream)) =>
          @mttp_core.read_bounded(stream.take(), 1 << 20) catch {
            _ => return json(400, { "error": "unreadable body" })
          }
        (_, Stream(stream)) =>
          stream.take().read_some().unwrap_or(b"") catch {
            _ => return json(400, { "error": "unreadable body" })
          }
        (_, Bytes(bytes)) => bytes
        _ => b""
      }
      if request.attributes.get(@mttp_core.background) is Some(schedule) {
        schedule(() => {
          @async.sleep(200)
          slow.val += 1
        })
      }
      json(200, { "read": Json::number(bytes.length().to_double()) })
    }
    // Discards the body unread and refuses with an empty reply, as an
    // endpoint does when a required header is missing.
    (Post, Some("reject")) => {
      if request.body is Stream(stream) {
        stream.close()
      }
      @mttp_core.Response::new(401)
    }
    (Get, Some("slow")) =>
      json(200, { "finished": Json::number(slow.val.to_double()) })
    (Get, Some("notes")) =>
      json(200, { "notes": Json::array(notes.map(Json::string)) })
    _ => json(404, { "error": "not found" })
  }
}

///|
let adapter : (@fetch.JsRequest, @fetch.JsBackground) -> @fetch.JsPromise = @fetch.fetch_handler(
  route,
)

///|
/// The Workers entry: associates the bindings with the request, then handles
/// it.
pub fn fetch_with_env(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
  env : @fetch.JsEnv,
) -> @fetch.JsPromise {
  adapter(@fetch.with_env(request, env), background)
}
