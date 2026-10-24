///|
pub(all) struct RequestOptions {
  timeout_ms : Int?
  max_body_bytes : Int
}

///|
pub fn RequestOptions::default() -> RequestOptions {
  { timeout_ms: None, max_body_bytes: 64 * 1024 * 1024 }
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
pub fn from_fn(f : SendFn, on_close? : () -> Unit = () => ()) -> &Backend {
  FnBackend::{ f, on_close }
}

///|
pub(all) suberror ResponseError {
  UnexpectedStatus(@model.ResponseHead, body~ : Bytes)
  Deserialization(@model.ResponseHead, message~ : String, body~ : Bytes)
} derive(Debug)

///|
pub fn status_of(e : Error) -> Int? {
  match e {
    UnexpectedStatus(h, ..) | Deserialization(h, ..) => Some(h.status)
    _ => None
  }
}

///|
const ERROR_BODY_LIMIT : Int = 1048576

///|
pub struct ResponseAs[T] {
  priv accept_head : (@model.ResponseHead) -> Bool
  priv read : async (@model.ResponseHead, @model.Body, RequestOptions) -> T
  priv streaming : Bool
}

///|
pub async fn read_bounded(
  body : @model.Body,
  limit : Int,
) -> Bytes raise @model.TransportError {
  match body {
    Empty => b""
    Bytes(b) => b
    Stream(s, ..) => {
      let buf = Buffer()
      while s.read_some() is Some(chunk) {
        if buf.length() + chunk.length() > limit {
          raise TransportError(
            kind=TooLarge(limit=limit.to_int64()),
            phase=Body,
            detail="over limit",
          )
        }
        buf.write_bytes(chunk)
      }
      buf.to_bytes()
    }
  }
}

///|
fn is_2xx(h : @model.ResponseHead) -> Bool {
  h.status >= 200 && h.status < 300
}

///|
pub fn as_bytes() -> ResponseAs[Bytes] {
  {
    accept_head: is_2xx,
    read: async fn(_head, body, opts) { read_bounded(body, opts.max_body_bytes) },
    streaming: false,
  }
}

///|
pub fn as_bytes_always() -> ResponseAs[Bytes] {
  {
    accept_head: _ => true,
    read: async fn(_head, body, opts) { read_bounded(body, opts.max_body_bytes) },
    streaming: false,
  }
}

///|
pub fn[A, B] ResponseAs::map(
  self : ResponseAs[A],
  f : (A) -> B raise,
) -> ResponseAs[B] {
  let read = self.read
  {
    accept_head: self.accept_head,
    read: async fn(h, b, o) { f(read(h, b, o)) },
    streaming: self.streaming,
  }
}

///|
pub fn[A, B] ResponseAs::map_with_head(
  self : ResponseAs[A],
  f : (A, @model.ResponseHead) -> B raise,
) -> ResponseAs[B] {
  let read = self.read
  {
    accept_head: self.accept_head,
    read: async fn(h, b, o) { f(read(h, b, o), h) },
    streaming: self.streaming,
  }
}

///|
pub(all) struct SseEvent {
  data : String
}

///|
/// Simplified SSE reader (one `data:` line per event), Streaming mode.
pub fn as_sse(f : async (SseEvent) -> Unit) -> ResponseAs[Unit] {
  {
    accept_head: is_2xx,
    read: async fn(_h, body, _o) {
      guard body is Stream(s, ..) else { return }
      let pending = Buffer()
      while s.read_some() is Some(chunk) {
        pending.write_bytes(chunk)
        let text = @utf8.decode_lossy(pending.to_bytes())
        let parts = text.split("\n\n").map(p => p.to_owned()).collect()
        pending.reset()
        pending.write_bytes(@utf8.encode(parts[parts.length() - 1]))
        for i in 0..<(parts.length() - 1) {
          let p = parts[i]
          if p.has_prefix("data: ") {
            f({ data: p[6:].to_owned() })
          }
        }
      }
    },
    streaming: true,
  }
}

///|
pub(open) trait RequestBuilder {
  raw(Self) -> @model.Request
  with_raw(Self, @model.Request) -> Self
  header(Self, String, String) -> Self = _
}

///|
impl RequestBuilder with header(self, name, value) {
  let r = self.raw()
  self.with_raw({ ..r, headers: r.headers.add(name, value) })
}

///|
pub let rate_limit_bucket : @model.AttributeKey[String] = @model.AttributeKey::new()

///|
pub struct PartialRequest[T] {
  priv raw : @model.Request
  priv options : RequestOptions
  priv response_as : ResponseAs[T]
  priv base : @model.Url?
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
pub extend PartialRequest with RequestBuilder::{header}

///|
pub extend ClientRequest with RequestBuilder::{header}

///|
pub let basic_request : PartialRequest[Bytes] = {
  raw: @model.Request::new(Get, @model.Url::parse("/") catch { _ => abort("unreachable") }),
  options: RequestOptions::default(),
  response_as: as_bytes(),
  base: None,
}

///|
pub fn[T] PartialRequest::base_url(
  self : PartialRequest[T],
  base : @model.Url,
) -> PartialRequest[T] {
  { ..self, base: Some(base) }
}

///|
fn[T] PartialRequest::target(self : PartialRequest[T], url : @model.Url) -> @model.Url {
  match self.base {
    Some(b) => b.resolve(url)
    None => url
  }
}

///|
pub fn[T] PartialRequest::get(
  self : PartialRequest[T],
  url : @model.Url,
) -> ClientRequest[T] {
  {
    raw: { ..self.raw, meth: Get, url: self.target(url) },
    options: self.options,
    response_as: self.response_as,
  }
}

///|
pub fn[T] PartialRequest::post(
  self : PartialRequest[T],
  url : @model.Url,
) -> ClientRequest[T] {
  {
    raw: { ..self.raw, meth: Post, url: self.target(url) },
    options: self.options,
    response_as: self.response_as,
  }
}

///|
pub fn[T, U] ClientRequest::response(
  self : ClientRequest[T],
  ra : ResponseAs[U],
) -> ClientRequest[U] {
  { raw: self.raw, options: self.options, response_as: ra }
}

///|
pub fn[T, A] ClientRequest::attribute(
  self : ClientRequest[T],
  key : @model.AttributeKey[A],
  value : A,
) -> ClientRequest[T] {
  { ..self, raw: { ..self.raw, attributes: self.raw.attributes.put(key, value) } }
}

///|
pub(all) struct RetryContext {
  request : @model.Request
  bucket : String
  attempt : Int
}

///|
pub(all) enum Decision {
  Wait(Int)
  Stop
} derive(Debug, Eq)

///|
pub(open) trait RetryDecider {
  decide(Self, Error, RetryContext) -> Decision
}

///|
/// Architecture §3.4 Attempt: no `body` field (sdk-runtime's Attempt had one).
pub(all) struct Attempt {
  request : @model.Request
  bucket : String
  attempt : Int
  status : Int
  headers : @model.Headers
  error : Error?
  decision : Decision?
}

///|
pub struct Policy {
  priv clock : &@model.Clock
  priv retry : &RetryDecider
  priv observer : (Attempt) -> Unit
}

///|
pub fn Policy::new(
  clock : &@model.Clock,
  retry : &RetryDecider,
  observer? : (Attempt) -> Unit = _ => (),
) -> Policy {
  { clock, retry, observer }
}

///|
pub(all) struct Response[T] {
  status : Int
  headers : @model.Headers
  body : T
}

///|
priv enum Exchanged[T] {
  Done(Response[T])
  Pending(@model.Response) // streaming: head accepted, read after the loop
}

///|
async fn[T] attempt(
  req : ClientRequest[T],
  backend : &Backend,
) -> Exchanged[T] {
  let resp = backend.send(req.raw, req.options)
  let head = resp.head()
  if !(req.response_as.accept_head)(head) {
    defer resp.close()
    let body = read_bounded(resp.body, ERROR_BODY_LIMIT)
    raise UnexpectedStatus(head, body~)
  }
  if req.response_as.streaming {
    return Pending(resp)
  }
  defer resp.close()
  let body = (req.response_as.read)(head, resp.body, req.options)
  Done({ status: resp.status, headers: resp.headers, body })
}

///|
pub async fn[T] ClientRequest::send(
  self : ClientRequest[T],
  backend : &Backend,
  policy? : Policy,
) -> Response[T] {
  let bucket = self.raw.attributes.get(rate_limit_bucket).unwrap_or("default")
  let exchanged = for n = 0; ; n = n + 1 {
    let r : Result[Exchanged[T], Error] = try {
      Ok(attempt(self, backend))
    } catch {
      e => Err(e)
    }
    match (r, policy) {
      (Ok(v), Some(p)) => {
        let (status, headers) = match v {
          Done(d) => (d.status, d.headers)
          Pending(p) => (p.status, p.headers)
        }
        (p.observer)({ request: self.raw, bucket, attempt: n, status, headers, error: None, decision: None })
        break v
      }
      (Ok(v), None) => break v
      (Err(e), None) => raise e
      (Err(e), Some(p)) => {
        let d = p.retry.decide(e, { request: self.raw, bucket, attempt: n })
        let (status, headers) = match e {
          UnexpectedStatus(h, ..) => (h.status, h.headers)
          _ => (0, @model.Headers([]))
        }
        (p.observer)({ request: self.raw, bucket, attempt: n, status, headers, error: Some(e), decision: Some(d) })
        match d {
          Wait(ms) => p.clock.sleep(ms)
          Stop => raise e
        }
      }
    }
  }
  match exchanged {
    Done(d) => d
    Pending(resp) => {
      defer resp.close()
      let body = (self.response_as.read)(resp.head(), resp.body, self.options)
      { status: resp.status, headers: resp.headers, body }
    }
  }
}

///|
pub(all) struct Page[T] {
  items : Array[T]
  next : String?
}

///|
pub struct Paginator[T, E] {
  priv fetch : async (String?) -> Result[Page[T], E] noraise
  priv mut cursor : String?
  priv mut done : Bool
}

///|
pub fn[T, E : Error] Paginator::with_cursor(
  f : async (String?) -> Page[T] raise E,
) -> Paginator[T, E] {
  {
    fetch: c => Ok(f(c)) catch { e => Err(e) },
    cursor: None,
    done: false,
  }
}

///|
pub async fn[T, E : Error] Paginator::next_page(
  self : Paginator[T, E],
) -> Array[T]? raise E {
  if self.done {
    return None
  }
  let page = match (self.fetch)(self.cursor) {
    Ok(p) => p
    Err(e) => raise e
  }
  self.cursor = page.next
  if page.next is None {
    self.done = true
  }
  Some(page.items)
}

///|
pub async fn[T, E : Error] Paginator::collect(
  self : Paginator[T, E],
) -> Array[T] raise E {
  let out = []
  while self.next_page() is Some(items) {
    out.push_iter(items.iter())
  }
  out
}
