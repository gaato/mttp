///|
/// A message representation and its schema. The underlying Session bounds
/// wire/message bytes; JSON parsing uses JsonCodec's bounded body decoder.
pub struct WsCodec[T] {
  priv text : Bool
  priv body : @schema.BodyCodec[T]
}

///|
/// JSON in a Text message, validated by the same codec as HTTP JSON bodies.
pub fn[T] ws_json(codec : @schema.JsonCodec[T]) -> WsCodec[T] {
  { text: true, body: codec.body(), }
}

///|
/// UTF-8 Text messages.
pub fn ws_text() -> WsCodec[String] {
  { text: true, body: @schema.text_body, }
}

///|
/// Binary messages.
pub fn ws_binary() -> WsCodec[Bytes] {
  { text: false, body: @schema.raw_bytes, }
}

///|
/// Documentation for one message, independent of OpenAPI's handshake.
pub fn[T] WsCodec::schema(self : WsCodec[T]) -> @schema.Schema {
  self.body.schema()
}

///|
fn[T] WsCodec::encode(self : WsCodec[T], value : T) -> @ws.Message {
  let bytes = self.body.encode(value)
  if self.text {
    Text(@utf8.decode_lossy(bytes))
  } else {
    Binary(bytes)
  }
}

///|
fn[T] WsCodec::decode(
  self : WsCodec[T],
  message : @ws.Message,
) -> T raise @schema.DecodeFailure {
  let bytes = match (self.text, message) {
    (true, Text(text)) => @utf8.encode(text)
    (false, Binary(bytes)) => bytes
    _ =>
      raise @schema.DecodeFailure(
        kind=Mismatch(
          expected=if self.text { "Text" } else { "Binary" },
          actual=if message is Text(_) { "Text" } else { "Binary" },
        ),
        message="wrong WebSocket message type",
      )
  }
  self.body.decode(bytes)
}

///|
/// A receive failure retains either the transport error or the codec issue
/// and the Close code sent to the peer (1003 for type, 1007 for contents).
#derive(Debug)
pub(all) suberror WsReceiveError {
  SessionFailure(@ws.WsError)
  MessageDecode(code~ : @ws.CloseCode, failure~ : @schema.DecodeFailure)
}

///|
/// Formats a receive failure with its original typed cause.
pub extend WsReceiveError with @debug.Debug::{to_repr}

///|
/// A Session with receive/send types. Copies share the underlying session.
pub struct TypedSession[R, W] {
  priv session : &@ws.Session
  priv incoming : WsCodec[R]
  priv outgoing : WsCodec[W]
}

///|
/// Wraps a message Session, including a scripted peer, without buffering.
pub fn[R, W] TypedSession::new(
  session : &@ws.Session,
  incoming~ : WsCodec[R],
  outgoing~ : WsCodec[W],
) -> TypedSession[R, W] {
  { session, incoming, outgoing, }
}

///|
/// Receives one value. A decode failure completes the bounded Close handshake
/// before raising the typed issue; transport failures retain their WsError.
pub async fn[R, W] TypedSession::recv(
  self : TypedSession[R, W],
) -> R raise WsReceiveError {
  let message = self.session.recv() catch {
    error => raise SessionFailure(error)
  }
  self.incoming.decode(message) catch {
    failure => {
      let code : @ws.CloseCode = if self.incoming.text != (message is Text(_)) {
        UnsupportedData
      } else {
        InvalidPayload
      }
      self.session.close({ code, reason: "message decode failed", })
      raise MessageDecode(code~, failure~)
    }
  }
}

///|
/// Encodes and sends one value under the underlying Session's send bound.
pub async fn[R, W] TypedSession::send(
  self : TypedSession[R, W],
  value : W,
) -> Unit raise @ws.WsError {
  self.session.send(self.outgoing.encode(value))
}

///|
/// Completes the bounded Close handshake, idempotently.
pub async fn[R, W] TypedSession::close(
  self : TypedSession[R, W],
  frame : @ws.CloseFrame,
) -> Unit noraise {
  self.session.close(frame)
}

///|
/// Immediately drops the connection, idempotently.
pub fn[R, W] TypedSession::abort(self : TypedSession[R, W]) -> Unit {
  self.session.abort()
}

///|
/// The negotiated subprotocol, if any.
pub fn[R, W] TypedSession::subprotocol(self : TypedSession[R, W]) -> String? {
  self.session.subprotocol()
}
