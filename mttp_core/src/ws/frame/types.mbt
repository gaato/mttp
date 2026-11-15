///|
/// The six opcodes RFC 6455 defines. Reserved wire values are refused.
#derive(Eq, Debug)
pub(all) enum Opcode {
  Continuation
  Text
  Binary
  Close
  Ping
  Pong
}

///|
/// Compares frame opcodes.
pub extend Opcode with Eq::{equal, not_equal}

///|
/// Formats frame opcodes.
pub extend Opcode with @debug.Debug::{to_repr}

///|
/// The reading endpoint: servers require masks, clients refuse them.
#derive(Eq, Debug)
pub(all) enum Role {
  Client
  Server
}

///|
/// Compares endpoint roles.
pub extend Role with Eq::{equal, not_equal}

///|
/// Formats endpoint roles.
pub extend Role with @debug.Debug::{to_repr}

///|
/// Frame metadata. Length counts wire payload bytes, excluding the mask key.
#derive(Eq, Debug)
pub(all) struct FrameHead {
  fin : Bool
  rsv1 : Bool
  opcode : Opcode
  masked : Bool
  length : Int64
}

///|
/// Constructs frame metadata; RSV1 defaults to false.
pub fn FrameHead::new(
  fin~ : Bool,
  rsv1~ : Bool = false,
  opcode~ : Opcode,
  masked~ : Bool,
  length~ : Int64,
) -> FrameHead {
  { fin, rsv1, opcode, masked, length, }
}

///|
/// Compares frame metadata.
pub extend FrameHead with Eq::{equal, not_equal}

///|
/// Formats frame metadata.
pub extend FrameHead with @debug.Debug::{to_repr}

///|
/// Each frame yields Head, zero or more unmasked Payload pieces, then End.
/// Piece boundaries follow available input, not message boundaries.
#derive(Eq, Debug)
pub(all) enum Event {
  Head(FrameHead)
  Payload(Bytes)
  End
}

///|
/// Compares frame events, including payload bytes.
pub extend Event with Eq::{equal, not_equal}

///|
/// Formats frame events.
pub extend Event with @debug.Debug::{to_repr}

///|
/// Stable refusal categories, with RFC 6455 close-code mappings.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum FrameErrorKind {
  Protocol
  TooLarge(limit~ : Int32)
}

///|
/// Compares frame refusal categories.
pub extend FrameErrorKind with Eq::{equal, not_equal}

///|
/// Formats frame refusal categories.
pub extend FrameErrorKind with @debug.Debug::{to_repr}

///|
/// Maps protocol errors to 1002 and oversized frames to 1009.
pub fn FrameErrorKind::close_code(self : FrameErrorKind) -> Int32 {
  match self {
    Protocol => 1002
    TooLarge(..) => 1009
  }
}

///|
/// Diagnostic detail may change; match kind. Parser errors are permanent.
#derive(Debug)
pub(all) suberror FrameError {
  FrameError(kind~ : FrameErrorKind, detail~ : String)
}

///|
/// Formats frame refusals for diagnostics.
pub extend FrameError with @debug.Debug::{to_repr}

///|
fn protocol(detail : String) -> FrameError {
  FrameError(kind=Protocol, detail~)
}

///|
fn Opcode::wire(self : Opcode) -> Int32 {
  match self {
    Continuation => 0
    Text => 1
    Binary => 2
    Close => 8
    Ping => 9
    Pong => 10
  }
}

///|
fn opcode_of(wire : Int32) -> Opcode raise FrameError {
  match wire {
    0 => Continuation
    1 => Text
    2 => Binary
    8 => Close
    9 => Ping
    10 => Pong
    _ => raise protocol("reserved opcode")
  }
}

///|
fn validate(head : FrameHead) -> Unit raise FrameError {
  if head.length < 0L {
    raise protocol("negative payload length")
  }
  if head.opcode.wire() >= 8 && (!head.fin || head.length > 125L || head.rsv1) {
    raise protocol("invalid control frame")
  }
  if head.opcode is Close && head.length == 1L {
    raise protocol("one-byte Close payload")
  }
}
