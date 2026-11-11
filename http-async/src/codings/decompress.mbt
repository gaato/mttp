///|
priv struct DecodedBody {
  read : async () -> Bytes? raise @mttp.TransportError
  close_ : () -> Unit
  decoder : ContentDecoder
  mut closed : Bool
}

///|
impl @mttp.BodyStream for DecodedBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @mttp.BodyStream::close(self)
  let bytes = read_decoded(() => (self.read)(), Some(self.decoder)) catch {
    @mttp.TransportError(..) as error => raise error
    _ =>
      raise @mttp.TransportError(
        kind=Protocol,
        phase=Body,
        detail="content decoding failed",
      )
  }
  if bytes is None {
    @mttp.BodyStream::close(self)
  }
  bytes
}

///|
impl @mttp.BodyStream for DecodedBody with fn close(self) {
  if !self.closed {
    self.closed = true
    (self.close_)()
    for stage in self.decoder.stages {
      stage.input = b""[:]
      stage.sniffed = b""
    }
  }
}

///|
/// A backend that negotiates and lazily undoes content codings. Any caller
/// supplied Accept-Encoding opts out, including identity. SendOptions are
/// passed unchanged: the inner engine bounds wire bytes, readers bound decoded
/// bytes. Each decoded slice is at most 64 KiB.
pub struct Decompress {
  priv inner : &@mttp.Backend
  priv mut closed : Bool
}

///|
/// Wraps inner, transferring backend closure to this wrapper.
pub fn Decompress::new(inner : &@mttp.Backend) -> Decompress {
  { inner, closed: false, }
}

///|
/// Makes the Backend operations available as methods.
pub extend Decompress with @mttp.Backend::{send, close}

///|
/// Validates before delegating, then transfers the received body to a lazy
/// decoded stream when this wrapper negotiated its encoding.
pub impl @mttp.Backend for Decompress with fn send(self, request, options) {
  if self.closed {
    raise @mttp.TransportError(kind=Closed, phase=Pool, detail="backend closed")
  }
  request.validate()
  options.validate()
  let decode = !request.headers.contains("accept-encoding")
  let sent = if decode {
    request.set_header("accept-encoding", accept_encoding())
  } else {
    request
  }
  let response = self.inner.send(sent, options)
  errdefer response.close()
  if !decode || !has_body(request.meth.to_string(), response.status) {
    return response
  }
  let (head, decoder) = decode_head(response.head())
  guard decoder is Some(decoder) else { return response }
  let (read, close_) = body_source(response.body)
  {
    ..response,
    headers: head.headers,
    body: Stream(
      @mttp.StreamBody::new(DecodedBody::{
        read,
        close_,
        decoder,
        closed: false,
      }),
    ),
  }
}

///|
/// Closes the inner backend exactly once and refuses subsequent sends.
pub impl @mttp.Backend for Decompress with fn close(self) {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}
