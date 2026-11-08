///|
priv struct EncodedBody {
  read : async () -> Bytes? raise @http.TransportError
  close_ : () -> Unit
  encoder : ContentEncoder
  mut closed : Bool
}

///|
impl @http.BodyStream for EncodedBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @http.BodyStream::close(self)
  let chunk = read_encoded(() => (self.read)(), self.encoder) catch {
    @http.TransportError(..) as error => raise error
    _ =>
      raise @http.TransportError(
        kind=Protocol,
        phase=Body,
        detail="content encoding failed",
      )
  }
  if chunk is None {
    @http.BodyStream::close(self)
  }
  chunk
}

///|
impl @http.BodyStream for EncodedBody with fn close(self) {
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
  body : @http.Body,
  coding : Coding,
) -> @http.Body raise @http.TransportError {
  let encoder = ContentEncoder::new(coding)
  let (read, close_) = body_source(body)
  @http.Body::Stream(
    @http.StreamBody::new(EncodedBody::{ read, close_, encoder, closed: false, }),
  )
}
