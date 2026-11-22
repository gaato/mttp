// The events of a session: h2_stub.c records them as it goes, and
// `H2Session::events` decodes the records here.

///|
/// An HTTP/2 error code (RFC 9113, section 7).
#derive(Eq, Debug)
pub(all) enum ErrorCode {
  NoError
  ProtocolError
  InternalError
  FlowControlError
  SettingsTimeout
  StreamClosed
  FrameSizeError
  RefusedStream
  Cancel
  CompressionError
  ConnectError
  EnhanceYourCalm
  InadequateSecurity
  Http11Required
  /// A code this list does not name.
  Other(Int32)
}

///|
/// Compares error codes.
pub extend ErrorCode with Eq::{equal, not_equal}

///|
/// Formats an error code for diagnostics.
pub extend ErrorCode with @debug.Debug::{to_repr}

///|
/// The code's value on the wire.
pub fn ErrorCode::to_int(self : ErrorCode) -> Int32 {
  match self {
    NoError => 0x0
    ProtocolError => 0x1
    InternalError => 0x2
    FlowControlError => 0x3
    SettingsTimeout => 0x4
    StreamClosed => 0x5
    FrameSizeError => 0x6
    RefusedStream => 0x7
    Cancel => 0x8
    CompressionError => 0x9
    ConnectError => 0xa
    EnhanceYourCalm => 0xb
    InadequateSecurity => 0xc
    Http11Required => 0xd
    Other(code) => code
  }
}

///|
/// The code with this value on the wire.
pub fn ErrorCode::from_int(code : Int32) -> ErrorCode {
  match code {
    0x0 => NoError
    0x1 => ProtocolError
    0x2 => InternalError
    0x3 => FlowControlError
    0x4 => SettingsTimeout
    0x5 => StreamClosed
    0x6 => FrameSizeError
    0x7 => RefusedStream
    0x8 => Cancel
    0x9 => CompressionError
    0xa => ConnectError
    0xb => EnhanceYourCalm
    0xc => InadequateSecurity
    0xd => Http11Required
    _ => Other(code)
  }
}

///|
/// What a header block is, as nghttp2 sorts it.
#derive(Eq, Debug)
pub(all) enum BlockKind {
  /// A request's header fields (a server's view).
  Request
  /// A response's, an interim (1xx) one included (a client's view).
  Response
  /// Trailer fields, after a body.
  Trailers
  /// A pushed request; a client refuses push, so none arrives.
  Push
}

///|
/// Compares block kinds.
pub extend BlockKind with Eq::{equal, not_equal}

///|
/// Formats a block kind for diagnostics.
pub extend BlockKind with @debug.Debug::{to_repr}

///|
/// Something a step of the session caused. Later versions may add events:
/// match the ones you need and pass over the rest (`H2Event::..`).
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum H2Event {
  /// A whole header block arrived on `stream`: its fields in order, pseudo
  /// fields first, and whether its frame ended the stream.
  Headers(
    stream~ : Int32,
    kind~ : BlockKind,
    fields~ : Array[(String, String)],
    end_stream~ : Bool,
  )
  /// Body bytes arrived on `stream`. They count against both windows until
  /// `consume_connection` and `consume_stream` acknowledge them.
  Data(stream~ : Int32, Bytes)
  /// The peer ended `stream` with a DATA frame.
  EndStream(stream~ : Int32)
  /// `stream` closed: both ends finished (`NoError`), or a reset by either
  /// end with its code.
  Closed(stream~ : Int32, code~ : ErrorCode)
  /// The peer sent GOAWAY: streams above `last_stream` were not processed.
  GoAway(last_stream~ : Int32, code~ : ErrorCode)
  /// The peer's SETTINGS arrived, with its SETTINGS_MAX_CONCURRENT_STREAMS.
  Settings(max_concurrent_streams~ : Int32)
  /// A HEADERS or DATA frame of `stream` went out; with `end_stream`, the
  /// last of this end's half.
  Sent(stream~ : Int32, end_stream~ : Bool)
  /// `stream`'s body queue fell below the low mark.
  Drained(stream~ : Int32)
  /// A frame of `stream` could not be sent (nghttp2's code): the stream
  /// closed or the session refused it, for example after GOAWAY.
  NotSent(stream~ : Int32, code~ : Int32)
  /// `stream`'s header block crossed `max_header_list`; nghttp2 reset the
  /// stream with INTERNAL_ERROR, and its `Closed` follows.
  TooLarge(stream~ : Int32)
  /// The peer acknowledged a PING.
  PingAck
}

///|
/// Compares events.
pub extend H2Event with Eq::{equal, not_equal}

///|
/// Formats an event for diagnostics.
pub extend H2Event with @debug.Debug::{to_repr}

///|
/// A reader over the event records.
priv struct Cursor {
  data : Bytes
  mut at : Int32
}

///|
fn Cursor::byte(self : Cursor) -> Int32 {
  let v = self.data[self.at].to_int()
  self.at += 1
  v
}

///|
fn Cursor::int(self : Cursor) -> Int32 {
  let v = (self.data[self.at].to_int() << 24) |
    (self.data[self.at + 1].to_int() << 16) |
    (self.data[self.at + 2].to_int() << 8) |
    self.data[self.at + 3].to_int()
  self.at += 4
  v
}

///|
fn Cursor::blob(self : Cursor) -> BytesView {
  let len = self.int()
  let view = self.data[self.at:self.at + len]
  self.at += len
  view
}

///|
/// Each octet as the code point of the same value (ISO-8859-1).
fn latin1(bytes : BytesView) -> String {
  let out = StringBuilder(capacity=bytes.length())
  for byte in bytes {
    out.write_char(byte.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
fn kind_of(category : Int32) -> BlockKind {
  // nghttp2_headers_category: REQUEST 0, RESPONSE 1, PUSH_RESPONSE 2,
  // HEADERS 3 (trailers, or the final response after an interim one).
  match category {
    0 => Request
    1 => Response
    2 => Push
    _ => Trailers
  }
}

///|
/// Decodes the records h2_stub.c wrote. Header fields between a block's
/// begin and end records are gathered into one `Headers`.
fn decode_events(data : Bytes) -> Array[H2Event] {
  let events = []
  let cursor = { data, at: 0, }
  let blocks : Map[Int32, Array[(String, String)]] = Map([])
  while cursor.at < data.length() {
    match cursor.byte() {
      1 => {
        let stream = cursor.int()
        ignore(cursor.int())
        blocks[stream] = []
      }
      2 => {
        let stream = cursor.int()
        let name = latin1(cursor.blob())
        let value = latin1(cursor.blob())
        match blocks.get(stream) {
          Some(fields) => fields.push((name, value))
          None => blocks[stream] = [(name, value)]
        }
      }
      3 => {
        let stream = cursor.int()
        let category = cursor.int()
        let end_stream = cursor.int() != 0
        let fields = blocks.get(stream).unwrap_or([])
        blocks.remove(stream)
        events.push(
          Headers(stream~, kind=kind_of(category), fields~, end_stream~),
        )
      }
      4 => {
        let stream = cursor.int()
        events.push(Data(stream~, cursor.blob().to_owned()))
      }
      5 => events.push(EndStream(stream=cursor.int()))
      6 => {
        let stream = cursor.int()
        blocks.remove(stream)
        events.push(Closed(stream~, code=ErrorCode::from_int(cursor.int())))
      }
      7 => {
        let last_stream = cursor.int()
        events.push(
          GoAway(last_stream~, code=ErrorCode::from_int(cursor.int())),
        )
      }
      8 => events.push(Settings(max_concurrent_streams=cursor.int()))
      9 => {
        let stream = cursor.int()
        events.push(Sent(stream~, end_stream=cursor.int() != 0))
      }
      10 => events.push(Drained(stream=cursor.int()))
      11 => {
        let stream = cursor.int()
        events.push(NotSent(stream~, code=cursor.int()))
      }
      12 => {
        let stream = cursor.int()
        blocks.remove(stream)
        events.push(TooLarge(stream~))
      }
      13 => events.push(PingAck)
      other => abort("h2_stub.c recorded an unknown event \{other}")
    }
  }
  events
}
