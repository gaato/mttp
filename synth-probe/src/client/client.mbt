///|
pub(all) struct RequestOptions {
  timeout_ms : Int?
  max_body_bytes : Int
  follow_redirects : Bool
  max_redirects : Int
}

///|
pub fn RequestOptions::default() -> RequestOptions {
  { timeout_ms: None, max_body_bytes: 64 * 1024 * 1024, follow_redirects: true, max_redirects: 10 }
}

///|
pub(open) trait Backend {
  async fn send(Self, @model.Request, RequestOptions) -> @model.Response raise @model.TransportError
  fn close(Self) -> Unit = _
}

///|
impl Backend with close(_self) {
  ()
}

///|
pub type SendFn = async (@model.Request, RequestOptions) -> @model.Response raise @model.TransportError

///|
priv struct FnBackend {
  f : SendFn
  on_close : () -> Unit
}

///|
impl Backend for FnBackend with send(self, req, opts) {
  (self.f)(req, opts)
}

///|
impl Backend for FnBackend with close(self) {
  (self.on_close)()
}

///|
/// Adapts a function (usually an arrow lambda) into a Backend.
pub fn from_fn(f : SendFn, on_close? : () -> Unit = () => ()) -> &Backend {
  FnBackend::{ f, on_close }
}

///|
/// A wrapper written as an arrow lambda over a closed error type.
pub fn with_header(inner : &Backend, name : String, value : String) -> &Backend {
  from_fn((req, opts) => inner.send({ ..req, headers: [..req.headers, (name, value)] }, opts), on_close=() => inner.close())
}

///|
pub(all) suberror ResponseError {
  UnexpectedStatus(@model.ResponseHead, body~ : Bytes)
  Deserialization(@model.ResponseHead, message~ : String, body~ : Bytes)
} derive(Debug)

///|
pub struct ResponseAs[T] {
  priv read : async (@model.ResponseHead, @model.Body, RequestOptions) -> T
  priv streaming : Bool
  priv show : String
}

///|
async fn read_bounded(body : @model.Body, limit : Int) -> Bytes raise @model.TransportError {
  match body {
    Empty => b""
    Bytes(b) => b
    Stream(s, ..) => {
      let buf = Buffer()
      while s.read_some() is Some(chunk) {
        if buf.length() + chunk.length() > limit {
          raise TransportError(kind=TooLarge(limit=limit.to_int64()), phase=Body, detail="body over limit")
        }
        buf.write_bytes(chunk)
      }
      buf.to_bytes()
    }
  }
}

///|
pub fn as_bytes() -> ResponseAs[Bytes] {
  {
    read: async fn(head, body, opts) {
      let b = read_bounded(body, opts.max_body_bytes)
      if head.status < 200 || head.status >= 300 {
        raise UnexpectedStatus(head, body=b)
      }
      b
    },
    streaming: false,
    show: "as_bytes",
  }
}

///|
pub fn[T : FromJson] as_json() -> ResponseAs[T] {
  as_bytes().map(b => {
    let s = @utf8.decode(b)
    @json.from_json(@json.parse(s))
  })
}

///|
/// `f` may raise anything (open), unlike a closed client error type.
pub fn[A, B] ResponseAs::map(self : ResponseAs[A], f : (A) -> B raise) -> ResponseAs[B] {
  let read = self.read
  { read: async fn(h, b, o) { f(read(h, b, o)) }, streaming: self.streaming, show: self.show + ".map" }
}

///|
pub fn[T] as_stream(f : async (@model.ResponseHead, &@model.BodyStream) -> T) -> ResponseAs[T] {
  {
    read: async fn(head, body, _opts) {
      match body {
        Stream(s, ..) => f(head, s)
        _ => abort("demo")
      }
    },
    streaming: true,
    show: "as_stream",
  }
}

///|
pub(open) trait RequestBuilder {
  raw(Self) -> @model.Request
  with_raw(Self, @model.Request) -> Self
  header(Self, String, String) -> Self = _
  attribute_bucket(Self, String) -> Self = _
}

///|
impl RequestBuilder with header(self, name, value) {
  let r = self.raw()
  self.with_raw({ ..r, headers: [..r.headers, (name, value)] })
}

///|
pub let rate_limit_bucket : @model.AttributeKey[String] = @model.AttributeKey::new()

///|
impl RequestBuilder with attribute_bucket(self, b) {
  let r = self.raw()
  self.with_raw({ ..r, attributes: r.attributes.put(rate_limit_bucket, b) })
}

///|
pub struct PartialRequest[T] {
  priv raw : @model.Request
  priv options : RequestOptions
  priv response_as : ResponseAs[T]
}

///|
pub struct ClientRequest[T] {
  priv raw : @model.Request
  priv options : RequestOptions
  priv response_as : ResponseAs[T]
}

///|
pub impl[T] RequestBuilder for PartialRequest[T] with raw(self) {
  self.raw
}

///|
pub impl[T] RequestBuilder for PartialRequest[T] with with_raw(self, r) {
  { ..self, raw: r }
}

///|
pub impl[T] RequestBuilder for ClientRequest[T] with raw(self) {
  self.raw
}

///|
pub impl[T] RequestBuilder for ClientRequest[T] with with_raw(self, r) {
  { ..self, raw: r }
}

///|
pub extend PartialRequest with RequestBuilder::{header, attribute_bucket}

///|
pub extend ClientRequest with RequestBuilder::{header, attribute_bucket}

///|
pub let basic_request : PartialRequest[Bytes] = {
  raw: { meth: Get, url: "", headers: [], body: Empty, attributes: @model.Attributes::empty() },
  options: RequestOptions::default(),
  response_as: as_bytes(),
}

///|
pub fn[T] PartialRequest::get(self : PartialRequest[T], url : String) -> ClientRequest[T] {
  { raw: { ..self.raw, meth: Get, url }, options: self.options, response_as: self.response_as }
}

///|
pub fn[T, U] ClientRequest::response(self : ClientRequest[T], ra : ResponseAs[U]) -> ClientRequest[U] {
  { raw: self.raw, options: self.options, response_as: ra }
}

///|
pub(all) struct RetryContext {
  attempt : Int
  remaining_ms : Int64?
  request : @model.Request
}

///|
pub(all) enum Decision {
  RetryAfter(Int)
  Stop
} derive(Debug)

///|
pub(open) trait RetryDecider {
  decide(Self, Error, RetryContext) -> Decision
}

///|
pub struct Policy {
  priv clock : &@model.Clock
  priv retry : &RetryDecider
}

///|
pub fn Policy::new(clock : &@model.Clock, retry : &RetryDecider) -> Policy {
  { clock, retry }
}

///|
pub(all) struct Response[T] {
  status : Int
  headers : Array[(String, String)]
  body : T
}

///|
/// One attempt: the exchange and, for buffered readers, the reader too.
async fn[T] attempt(
  req : ClientRequest[T],
  backend : &Backend,
) -> Response[T] {
  let resp = backend.send(req.raw, req.options)
  defer resp.close()
  let body = (req.response_as.read)(resp.head(), resp.body, req.options)
  { status: resp.status, headers: resp.headers, body }
}

///|
pub async fn[T] ClientRequest::send(
  self : ClientRequest[T],
  backend : &Backend,
  policy? : Policy,
) -> Response[T] {
  guard policy is Some(p) else { return attempt(self, backend) }
  for n = 0; ; n = n + 1 {
    let r : Result[Response[T], Error] = try { Ok(attempt(self, backend)) } catch { e => Err(e) }
    match r {
      Ok(v) => return v
      Err(e) =>
        match p.retry.decide(e, { attempt: n, remaining_ms: None, request: self.raw }) {
          RetryAfter(ms) => p.clock.sleep(ms)
          Stop => raise e
        }
    }
  }
}
