///|
/// How to read a response. `accept_head` false: the error body is read
/// inside the attempt (bounded by max_error_body) and `reject` raises the
/// error for it (UnexpectedStatus by default), so the RetryDecider sees it. `streaming` applies only
/// to the accepted body: true means it is read once, after the retry loop.
pub struct ResponseAs[T] {
  priv accept_head : (@model.ResponseHead) -> Bool
  priv reject : (@model.ResponseHead, Bytes) -> Unit raise
  priv read : async (@model.ResponseHead, @model.Body, RequestOptions) -> T
  priv streaming : Bool
}

///|
fn default_reject(h : @model.ResponseHead, body : Bytes) -> Unit raise {
  raise UnexpectedStatus(h, body~)
}

///|
pub fn[T] ResponseAs::new(
  read : async (@model.ResponseHead, @model.Body, RequestOptions) -> T,
  accept_head? : (@model.ResponseHead) -> Bool = h => @model.is_success(h.status),
  reject? : (@model.ResponseHead, Bytes) -> Unit raise = default_reject,
  streaming? : Bool = false,
) -> ResponseAs[T] {
  { accept_head, reject, read, streaming }
}

///|
pub async fn read_body(body : @model.Body, limit : Int) -> Bytes raise @model.TransportError {
  match body {
    Bytes(b) =>
      if b.length() > limit {
        raise @model.TransportError(kind=TooLarge(limit~), phase=Body, detail="body over \{limit} bytes")
      } else {
        b
      }
    Stream(s, ..) => @model.read_bounded(s, limit)
    _ => b""
  }
}

///|
pub fn as_bytes() -> ResponseAs[Bytes] {
  ResponseAs::new(async fn(_h, body, opts) { read_body(body, opts.max_body_bytes) })
}

///|
pub fn as_string() -> ResponseAs[String] {
  as_bytes().map(b => @utf8.decode_lossy(b))
}

///|
pub fn as_json_value() -> ResponseAs[Json] {
  as_bytes().map_with_head((b, h) => @json.parse(@utf8.decode(b)) catch {
    e => raise Deserialization(h, message=e.to_string(), body=b)
  })
}

///|
pub fn[T : FromJson] as_json() -> ResponseAs[T] {
  as_bytes().map_with_head((b, h) => {
    let j = @json.parse(@utf8.decode(b)) catch {
      e => raise Deserialization(h, message=e.to_string(), body=b)
    }
    @json.from_json(j) catch {
      e => raise Deserialization(h, message=e.to_string(), body=b)
    }
  })
}

///|
pub fn ignore_body() -> ResponseAs[Unit] {
  ResponseAs::new(async fn(_h, body, _o) { if body is Stream(s, ..) { s.close() } })
}

///|
/// Streaming: `f` runs once, after the loop; the stream is closed after it.
pub fn[T] as_stream(f : async (@model.ResponseHead, &@model.BodyStream) -> T) -> ResponseAs[T] {
  ResponseAs::new(
    async fn(h, body, _o) {
      let s : &@model.BodyStream = match body {
        Stream(s, ..) => s
        Bytes(b) => @model.BytesStream::new([b])
        _ => @model.BytesStream::new([])
      }
      defer s.close()
      f(h, s)
    },
    streaming=true,
  )
}

///|
/// Replaces the `_always` twins: any reader can take every status.
pub fn[T] ResponseAs::any_status(self : ResponseAs[T]) -> ResponseAs[T] {
  { ..self, accept_head: _ => true }
}

///|
/// Buffered choice by head: the chosen reader runs inside the attempt.
pub fn[T] from_head(choose : (@model.ResponseHead) -> ResponseAs[T]) -> ResponseAs[T] {
  ResponseAs::new(
    async fn(h, b, o) { (choose(h).read)(h, b, o) },
    accept_head=h => (choose(h).accept_head)(h),
    reject=(h, b) => (choose(h).reject)(h, b),
  )
}

///|
pub fn[A, B] ResponseAs::map(self : ResponseAs[A], f : (A) -> B raise) -> ResponseAs[B] {
  let read = self.read
  { accept_head: self.accept_head, reject: self.reject, read: async fn(h, b, o) { f(read(h, b, o)) }, streaming: self.streaming }
}

///|
pub fn[A, B] ResponseAs::map_with_head(
  self : ResponseAs[A],
  f : (A, @model.ResponseHead) -> B raise,
) -> ResponseAs[B] {
  let read = self.read
  { accept_head: self.accept_head, reject: self.reject, read: async fn(h, b, o) { f(read(h, b, o), h) }, streaming: self.streaming }
}

///|
pub fn[T] ResponseAs::is_streaming(self : ResponseAs[T]) -> Bool {
  self.streaming
}
