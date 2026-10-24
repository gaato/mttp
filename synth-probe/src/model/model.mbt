///|
#non_exhaustive
pub(all) enum Phase {
  Pool
  Dial
  Write
  Head
  Body
  Unknown
} derive(Eq, Debug)

///|
#non_exhaustive
pub(all) enum Kind {
  Invalid
  Connect
  Timeout(ms~ : Int)
  Network
  Protocol
  Proxy(status~ : Int)
  TooLarge(limit~ : Int64)
  TooManyRedirects(max~ : Int)
  RedirectRefused
  Unreplayable
} derive(Eq, Debug)

///|
pub(all) suberror TransportError {
  TransportError(kind~ : Kind, phase~ : Phase, detail~ : String)
} derive(Debug)

///|
pub fn TransportError::is_unsent(self : TransportError) -> Bool {
  let TransportError(kind~, phase~, ..) = self
  match (kind, phase) {
    (Connect, _) | (_, Pool) | (_, Dial) => true
    _ => false
  }
}

///|
pub(open) trait BodyStream {
  async fn read_some(Self) -> Bytes? raise TransportError
  fn close(Self) -> Unit
}

///|
pub(all) enum Body {
  Empty
  Bytes(Bytes)
  Stream(&BodyStream, length~ : Int64?)
}

///|
pub(all) enum Method {
  Get
  Post
  Other(String)
} derive(Eq, Debug)

///|
pub struct AttributeKey[T] {
  priv id : Int
  priv slot : Ref[T?]
}

///|
let next_key : Ref[Int] = { val: 0 }

///|
pub fn[T] AttributeKey::new() -> AttributeKey[T] {
  next_key.val += 1
  { id: next_key.val, slot: { val: None } }
}

///|
pub struct Attributes {
  priv entries : Map[Int, () -> Unit]
}

///|
pub fn Attributes::empty() -> Attributes {
  { entries: Map([]) }
}

///|
pub fn[T] Attributes::put(self : Attributes, k : AttributeKey[T], v : T) -> Attributes {
  let m = self.entries.copy()
  m[k.id] = () => k.slot.val = Some(v)
  { entries: m }
}

///|
pub fn[T] Attributes::get(self : Attributes, k : AttributeKey[T]) -> T? {
  match self.entries.get(k.id) {
    Some(f) => {
      f()
      let v = k.slot.val
      k.slot.val = None
      v
    }
    None => None
  }
}

///|
pub(all) struct Request {
  meth : Method
  url : String
  headers : Array[(String, String)]
  body : Body
  attributes : Attributes
}

///|
pub(all) struct ResponseHead {
  status : Int
  headers : Array[(String, String)]
} derive(Debug)

///|
pub(all) struct Response {
  status : Int
  headers : Array[(String, String)]
  body : Body
}

///|
pub fn Response::head(self : Response) -> ResponseHead {
  { status: self.status, headers: self.headers }
}

///|
pub fn Response::close(self : Response) -> Unit {
  if self.body is Stream(s, ..) {
    s.close()
  }
}

///|
pub(open) trait Clock {
  async fn sleep(Self, Int) -> Unit noraise
  fn now_unix_ms(Self) -> Int64
}
