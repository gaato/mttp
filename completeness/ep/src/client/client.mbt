///|
/// Moves bytes. Every status is a response (CONTRACT rule 1); only a failed
/// exchange raises. The response body may be a stream the caller must close.
pub(open) trait Backend {
  async send(Self, @model.Request) -> @model.Response raise @model.TransportError
}

///|
/// Opens WebSockets; a separate capability, as client4's WebSocketBackend.
pub(open) trait WebSocketBackend {
  async open(Self, @model.Request) -> (@model.ResponseHead, &@model.WebSocketIo) raise @model.TransportError
}

///|
/// The response arrived but is not what the caller asked for.
pub(all) suberror ResponseError {
  UnexpectedStatus(@model.ResponseHead, body~ : Bytes)
  Deserialization(@model.ResponseHead, message~ : String, body~ : Bytes)
} derive(Debug)

///|
/// Kept from an error body; the rest is not buffered (RESOURCE_BOUNDS).
pub let max_error_body : Int64 = 1048576L

///|
/// Default cap for buffered success bodies: refuse rather than degrade.
pub let default_max_body : Int64 = 16777216L

///|
/// How to turn a response into a `T`; a value combined before sending.
pub struct ResponseAs[T] {
  priv read : async (@model.ResponseHead, @model.Body) -> T
}

///|
pub fn[T] ResponseAs::new(
  read : async (@model.ResponseHead, @model.Body) -> T,
) -> ResponseAs[T] {
  { read, }
}

///|
pub async fn[T] ResponseAs::read(
  self : ResponseAs[T],
  head : @model.ResponseHead,
  body : @model.Body,
) -> T {
  (self.read)(head, body)
}

///|
pub async fn body_bytes(body : @model.Body, limit : Int64) -> Bytes raise @model.TransportError {
  match body {
    Empty => b""
    Bytes(b) =>
      if b.length().to_int64() > limit {
        raise LimitExceeded(what="body", limit~)
      } else {
        b
      }
    Stream(s, ..) => @model.read_bounded(s, limit)
  }
}

///|
pub fn as_bytes(limit? : Int64 = default_max_body) -> ResponseAs[Bytes] {
  { read: async fn(_, body) { body_bytes(body, limit) } }
}

///|
pub fn ignore_body() -> ResponseAs[Unit] {
  {
    read: async fn(_, body) {
      if body is Stream(s, ..) {
        s.close()
      }
    },
  }
}

///|
/// The body stream, unread; the caller owns it and must close it.
pub fn as_stream() -> ResponseAs[&@model.BodyStream] {
  {
    read: async fn(_, body) {
      match body {
        Stream(s, ..) => s
        Bytes(b) => @model.BytesStream::new([b])
        Empty => @model.BytesStream::new([])
      }
    },
  }
}

///|
pub fn[A, B] ResponseAs::map(self : ResponseAs[A], f : (A) -> B raise) -> ResponseAs[B] {
  { read: async fn(h, b) { f((self.read)(h, b)) } }
}

///|
/// Pick a reader by the head, e.g. a typed error body for 4xx.
pub fn[T] from_head(choose : (@model.ResponseHead) -> ResponseAs[T]) -> ResponseAs[T] {
  { read: async fn(h, b) { (choose(h).read)(h, b) } }
}

///|
/// sttp's asJsonOrFail: non-2xx raises UnexpectedStatus, bad JSON raises
/// Deserialization.
pub fn[T : FromJson] as_json_or_fail() -> ResponseAs[T] {
  {
    read: async fn(h, b) {
      if !h.status.is_success() {
        raise UnexpectedStatus(h, body=body_bytes(b, max_error_body))
      }
      let bytes = body_bytes(b, default_max_body)
      let text = @utf8.decode(bytes) catch {
        _ => raise Deserialization(h, message="not UTF-8", body=bytes)
      }
      @json.from_json(@json.parse(text)) catch {
        e => raise Deserialization(h, message=e.to_string(), body=bytes)
      }
    },
  }
}

///|
pub(all) struct RequestOptions {
  timeout_ms : Int?
  follow_redirects : Bool
  max_redirects : Int
} derive(Debug)

///|
/// sttp's Request[T]: what to send and how to read the answer, as a value.
pub struct ClientRequest[T] {
  priv request : @model.Request
  priv response_as : ResponseAs[T]
  priv options : RequestOptions
}

///|
pub fn[T] ClientRequest::new(
  request : @model.Request,
  response_as : ResponseAs[T],
) -> ClientRequest[T] {
  {
    request,
    response_as,
    options: { timeout_ms: None, follow_redirects: true, max_redirects: 10 },
  }
}

///|
pub fn[T] ClientRequest::request(self : ClientRequest[T]) -> @model.Request {
  self.request
}

///|
/// sttp's basicRequest: bodies as String, non-2xx as Err.
pub let basic_request : ClientRequest[Result[String, String]] = ClientRequest::new(
  @model.Request::new(Get, @model.Uri::relative([])),
  from_head(h => as_bytes().map(b => {
    let s = @utf8.decode_lossy(b)
    if h.status.is_success() {
      Ok(s)
    } else {
      Err(s)
    }
  })),
)

///|
pub fn[T] ClientRequest::get(self : ClientRequest[T], uri : @model.Uri) -> ClientRequest[T] {
  { ..self, request: { ..self.request, meth: Get, uri } }
}

///|
pub fn[T] ClientRequest::post(self : ClientRequest[T], uri : @model.Uri) -> ClientRequest[T] {
  { ..self, request: { ..self.request, meth: Post, uri } }
}

///|
pub fn[T] ClientRequest::header(
  self : ClientRequest[T],
  name : String,
  value : String,
) -> ClientRequest[T] {
  {
    ..self,
    request: { ..self.request, headers: self.request.headers.add(name, value) },
  }
}

///|
pub fn[T, U] ClientRequest::response(
  self : ClientRequest[T],
  response_as : ResponseAs[U],
) -> ClientRequest[U] {
  { request: self.request, response_as, options: self.options }
}

///|
pub fn[T] ClientRequest::timeout(self : ClientRequest[T], ms : Int) -> ClientRequest[T] {
  { ..self, options: { ..self.options, timeout_ms: Some(ms) } }
}

///|
pub(all) struct Response[T] {
  head : @model.ResponseHead
  body : T
}

///|
/// Transport failures raise TransportError; what `response_as` raises
/// (ResponseError, or a declared endpoint error) passes through.
pub async fn[T] ClientRequest::send(
  self : ClientRequest[T],
  backend : &Backend,
) -> Response[T] {
  let raw = backend.send(self.request)
  let head = raw.head()
  defer {
    if raw.body is Stream(s, ..) {
      // reading to the end already closed it; close is idempotent (rule 11)
      ignore(s)
    }
  }
  { head, body: (self.response_as.read)(head, raw.body) }
}

///|
/// sttp's BackendStub: canned responses chosen by predicate, in order.
pub struct BackendStub {
  priv rules : Array[((@model.Request) -> Bool, async (@model.Request) -> @model.Response)]
  priv sent : Array[@model.Request]
}

///|
pub fn BackendStub::new() -> BackendStub {
  { rules: [], sent: [] }
}

///|
pub fn BackendStub::when(
  self : BackendStub,
  matches : (@model.Request) -> Bool,
  respond : async (@model.Request) -> @model.Response,
) -> BackendStub {
  self.rules.push((matches, respond))
  self
}

///|
pub fn BackendStub::sent(self : BackendStub) -> Array[@model.Request] {
  self.sent
}

///|
pub impl Backend for BackendStub with send(self, req) {
  self.sent.push(req)
  for rule in self.rules {
    if (rule.0)(req) {
      return (rule.1)(req) catch {
        @model.TransportError::_ as e => raise e
        e => raise Protocol("stub rule raised: \{e}")
      }
    }
  }
  { status: @model.Status(404), headers: @model.Headers::new(), body: Empty }
}

///|
/// Backend wrapper: retries per a pure policy, sleeping through an injected
/// clock (sans-IO: no runtime import).
pub(open) trait Clock {
  async sleep(Self, Int) -> Unit noraise
  now_ms(Self) -> Int64
}

///|
pub struct Retrying {
  priv inner : &Backend
  priv clock : &Clock
  priv max_retries : Int
  priv delay_ms : (Int) -> Int
}

///|
pub fn retrying(
  inner : &Backend,
  clock : &Clock,
  max_retries? : Int = 2,
  delay_ms? : (Int) -> Int = n => 500 * (1 << n),
) -> Retrying {
  { inner, clock, max_retries, delay_ms }
}

///|
pub impl Backend for Retrying with send(self, req) {
  let mut attempt = 0
  while true {
    let replayable = req.body.is_replayable()
    let resp = self.inner.send(req) catch {
      e =>
        if e.is_unsent() && attempt < self.max_retries {
          self.clock.sleep((self.delay_ms)(attempt))
          attempt += 1
          continue
        } else {
          raise e
        }
    }
    let code = resp.status.code()
    if (code == 503 || code == 429) &&
      replayable &&
      attempt < self.max_retries {
      if resp.body is Stream(s, ..) {
        s.close()
      }
      self.clock.sleep((self.delay_ms)(attempt))
      attempt += 1
      continue
    }
    return resp
  }
  panic()
}
