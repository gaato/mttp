///|
priv struct EncodedBody {
  read : async () -> Bytes? raise @model.TransportError
  close_ : () -> Unit
  encoder : ContentEncoder
  mut closed : Bool
}

///|
impl @model.BodyStream for EncodedBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @model.BodyStream::close(self)
  let chunk = read_encoded(() => (self.read)(), self.encoder) catch {
    @model.TransportError(..) as error => raise error
    _ =>
      raise @model.TransportError(
        kind=Protocol,
        phase=Body,
        detail="content encoding failed",
      )
  }
  if chunk is None {
    @model.BodyStream::close(self)
  }
  chunk
}

///|
impl @model.BodyStream for EncodedBody with fn close(self) {
  if !self.closed {
    self.closed = true
    (self.close_)()
    self.encoder.input = b""[:]
  }
}

///|
/// Wraps a body in a lazy compressed stream of unknown encoded length.
/// Transfers a streamed body's reader exactly once and closes it on EOF,
/// failure, cancellation or explicit close. Unsupported codings are refused
/// before taking the body. Buffered inputs are consumed in 64 KiB slices.
pub fn encode_body(
  body : @model.Body,
  coding : Coding,
) -> @model.Body raise @model.TransportError {
  let encoder = ContentEncoder::new(coding)
  let (read, close_) : (
    async () -> Bytes? raise @model.TransportError,
    () -> Unit,
  ) = match body {
    Stream(stream) => {
      let reader = stream.take()
      (() => reader.read_some(), () => reader.close())
    }
    _ => {
      let bytes = body.as_bytes().unwrap_or(b"")
      let offset = Ref(0)
      (
        () => {
          if offset.val == bytes.length() {
            return None
          }
          let end = offset.val + (bytes.length() - offset.val).min(65536)
          let chunk = bytes[offset.val:end].to_owned()
          offset.val = end
          Some(chunk)
        },
        () => (),
      )
    }
  }
  @model.Stream(
    @model.StreamBody::new(EncodedBody::{
      read,
      close_,
      encoder,
      closed: false,
    }),
  )
}
