///|
/// Compares message kind and contents.
pub extend Message with Eq::{equal, not_equal}

///|
/// Formats a message for diagnostics.
pub extend Message with @debug.Debug::{to_repr}

///|
/// Compares Close code constructors.
pub extend CloseCode with Eq::{equal, not_equal}

///|
/// Formats a Close code for diagnostics.
pub extend CloseCode with @debug.Debug::{to_repr}

///|
/// Compares a Close status and reason.
pub extend CloseFrame with Eq::{equal, not_equal}

///|
/// Formats a Close frame for diagnostics.
pub extend CloseFrame with @debug.Debug::{to_repr}

///|
/// Formats a failure category for diagnostics.
pub extend WsErrorKind with @debug.Debug::{to_repr}

///|
/// Formats a WebSocket failure for diagnostics.
pub extend WsError with @debug.Debug::{to_repr}

///|
/// Compares configured resource bounds.
pub extend WsLimits with Eq::{equal, not_equal}

///|
/// Formats resource bounds for diagnostics.
pub extend WsLimits with @debug.Debug::{to_repr}

///|
/// A complete UTF-8 text or opaque binary message.
#derive(Eq, Debug)
pub(all) enum Message {
  Text(String)
  Binary(Bytes)
}

///|
/// RFC 6455 Close status, including diagnostic-only and application values.
/// `Other` retains unknown integers; call sendable before putting one on wire.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum CloseCode {
  Normal
  GoingAway
  ProtocolError
  UnsupportedData
  NoStatus
  Abnormal
  InvalidPayload
  PolicyViolation
  MessageTooBig
  MissingExtension
  InternalError
  Other(Int32)
}

///|
/// The wire number, including reserved values retained for diagnostics.
pub fn CloseCode::to_int(self : CloseCode) -> Int32 {
  match self {
    Normal => 1000
    GoingAway => 1001
    ProtocolError => 1002
    UnsupportedData => 1003
    NoStatus => 1005
    Abnormal => 1006
    InvalidPayload => 1007
    PolicyViolation => 1008
    MessageTooBig => 1009
    MissingExtension => 1010
    InternalError => 1011
    Other(n) => n
  }
}

///|
/// Unknown values are retained for diagnostics; sendable validates the wire range.
pub fn CloseCode::from_int(n : Int32) -> CloseCode {
  match n {
    1000 => Normal
    1001 => GoingAway
    1002 => ProtocolError
    1003 => UnsupportedData
    1005 => NoStatus
    1006 => Abnormal
    1007 => InvalidPayload
    1008 => PolicyViolation
    1009 => MessageTooBig
    1010 => MissingExtension
    1011 => InternalError
    _ => Other(n)
  }
}

///|
/// RFC 6455 plus registered 1012-1014; unassigned protocol codes need negotiation.
pub fn CloseCode::sendable(self : CloseCode) -> Bool {
  let n = self.to_int()
  (n >= 1000 && n <= 1003) ||
  (n >= 1007 && n <= 1014) ||
  (n >= 3000 && n <= 4999)
}

///|
/// A Close payload. encode validates the status and the 123-byte UTF-8 reason.
#derive(Eq, Debug)
pub(all) struct CloseFrame {
  code : CloseCode
  reason : String
}

///|
/// A closed session or a framing, size, deadline, transport or upgrade failure.
/// Invalid text carries Closed(InvalidPayload), selecting Close 1007.
#derive(Debug)
#non_exhaustive
pub(all) enum WsErrorKind {
  Closed(CloseFrame)
  Protocol
  TooLarge(limit~ : Int32)
  Timeout(ms~ : Int32)
  Transport(@mttp_core.TransportError)
  Handshake(status~ : Int32)
}

///|
/// A structured failure with human-readable context.
#derive(Debug)
pub(all) suberror WsError {
  WsError(kind~ : WsErrorKind, detail~ : String)
}

///|
/// Message-level WebSocket over a byte connection or a host's WebSocket API.
/// Keep one recv task running to process controls and drive keepalive.
pub(open) trait Session {
  /// One receiving task. Cancellation retains assembly and committed messages.
  async fn recv(Self) -> Message raise WsError
  /// Sends one frame; callers queue in arrival order, including the deadline wait.
  async fn send(Self, Message) -> Unit raise WsError
  /// Sends Close once and waits a bounded time; cancellation aborts the connection.
  async fn close(Self, CloseFrame) -> Unit noraise
  /// Drops the transport immediately with local status 1006; idempotent.
  fn abort(Self) -> Unit
  /// The negotiated protocol, or None when the handshake selected none.
  fn subprotocol(Self) -> String?
}

///|
/// Negotiated per-message transformation. Controls never enter this interface.
pub(open) trait Extension {
  /// The extension's negotiation name.
  fn name(Self) -> String
  /// Returns transformed bytes and whether the first frame uses RSV1.
  fn encode(Self, Bytes) -> (Bytes, Bool)
  /// Decodes one complete message; enforce max_bytes while producing output.
  fn decode(Self, Bytes, rsv1~ : Bool, max_bytes~ : Int32) -> Bytes raise WsError
}

///|
/// Frame and wire/decoded message bytes, consecutive empty frames, and waits
/// in milliseconds. Unset or nonpositive keepalive options disable keepalive.
#derive(Eq, Debug)
pub(all) struct WsLimits {
  max_frame_bytes : Int32
  max_message_bytes : Int32
  max_empty_frames : Int32
  send_timeout_ms : Int32
  close_timeout_ms : Int32
  ping_interval_ms : Int32?
  pong_timeout_ms : Int32?
}

///|
/// 16 MiB frame/message, 1024 empty frames, 30 s sends, 5 s Close,
/// and 30 s Ping interval with a 10 s answer wait.
pub fn WsLimits::default() -> WsLimits {
  {
    max_frame_bytes: 16777216,
    max_message_bytes: 16777216,
    max_empty_frames: 1024,
    send_timeout_ms: 30000,
    close_timeout_ms: 5000,
    ping_interval_ms: Some(30000),
    pong_timeout_ms: Some(10000),
  }
}

///|
fn protocol(detail : String) -> WsError {
  WsError(kind=Protocol, detail~)
}

///|
/// Empty payload means NoStatus. Reserved codes and malformed reasons are refused.
pub fn CloseFrame::parse(payload : Bytes) -> CloseFrame raise WsError {
  if payload.is_empty() {
    return { code: NoStatus, reason: "", }
  }
  if payload.length() < 2 || payload.length() > 125 {
    raise protocol("invalid Close length")
  }
  let code = CloseCode::from_int(
    payload[0].to_int() * 256 + payload[1].to_int(),
  )
  if !code.sendable() {
    raise protocol("invalid Close code")
  }
  let reason = payload[2:]
  let validator = @frame.Utf8Validator::new()
  if !validator.push(reason) || !validator.finish() {
    raise WsError(
      kind=Closed({ code: InvalidPayload, reason: "", }),
      detail="invalid Close UTF-8",
    )
  }
  { code, reason: @utf8.decode_lossy(reason.to_owned()), }
}

///|
/// NoStatus with an empty reason encodes the absent status, never code 1005.
pub fn CloseFrame::encode(self : CloseFrame) -> Bytes raise WsError {
  if self.code.to_int() == 1005 && self.reason.is_empty() {
    return b""
  }
  if !self.code.sendable() {
    raise protocol("unsendable Close code")
  }
  let reason = @utf8.encode(self.reason)
  if reason.length() > 123 {
    raise protocol("Close reason exceeds 123 UTF-8 bytes")
  }
  let n = self.code.to_int()
  Bytes::from_array([(n >> 8).to_byte(), (n & 255).to_byte()]) + reason
}
