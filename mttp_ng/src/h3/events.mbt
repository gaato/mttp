// The events of a QUIC connection and its HTTP/3: h3_stub.c records them as
// it goes, and `QuicConn::events` decodes the records here.

///|
/// HTTP/3 error codes this package names (RFC 9114, section 8.1).
pub const H3_NO_ERROR : Int64 = 0x100L

///|
/// An internal error.
pub const H3_INTERNAL_ERROR : Int64 = 0x102L

///|
/// The peer was asked to do more than the endpoint allows.
pub const H3_EXCESSIVE_LOAD : Int64 = 0x107L

///|
/// The server did not process the request: it may be sent again.
pub const H3_REQUEST_REJECTED : Int64 = 0x10bL

///|
/// The request or its response is no longer wanted.
pub const H3_REQUEST_CANCELLED : Int64 = 0x10cL

///|
/// A malformed message (RFC 9114, section 4.1.2).
pub const H3_MESSAGE_ERROR : Int64 = 0x10eL

///|
/// Something a step of the connection caused. Later versions may add
/// events: match the ones you need and pass over the rest (`H3Event::..`).
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum H3Event {
  /// A whole header block arrived on `stream`: a request's (server) or a
  /// response's (client), interim ones included, pseudo fields first.
  Headers(
    stream~ : Int64,
    fields~ : Array[(String, String)],
    end_stream~ : Bool,
  )
  /// Body bytes arrived on `stream`; they count against its flow control
  /// until `consume` acknowledges them.
  Data(stream~ : Int64, Bytes)
  /// The peer ended `stream`.
  EndStream(stream~ : Int64)
  /// `stream` closed, with its HTTP/3 error code (`H3_NO_ERROR` when both
  /// halves ended).
  Closed(stream~ : Int64, code~ : Int64)
  /// The peer sent GOAWAY: a server's names the first request stream it
  /// will not process.
  GoAway(id~ : Int64)
  /// Data of `stream` went into a packet; with `end_stream`, its last.
  Sent(stream~ : Int64, end_stream~ : Bool)
  /// `stream`'s body queue fell below the low mark.
  Drained(stream~ : Int64)
  /// `stream`'s header block crossed the limit; the stream was ended with
  /// H3_EXCESSIVE_LOAD.
  TooLarge(stream~ : Int64)
  /// The handshake completed: requests may go.
  HandshakeDone
  /// The connection closed, with its error code, by the peer or not.
  ConnectionClosed(code~ : Int64, by_peer~ : Bool)
  /// A server's: data of `stream` arrived in 0-RTT, before the handshake
  /// completed, so its request may be a replay (RFC 8470). Comes before the
  /// stream's `Headers`.
  Early(stream~ : Int64)
  /// A client's: the server rejected its early data. The streams opened
  /// in 0-RTT are gone; their requests were not processed.
  EarlyDataRejected
  /// A client's: a session ticket arrived (`QuicConn::resumption`).
  Ticket
}

///|
/// Compares events.
pub extend H3Event with Eq::{equal, not_equal}

///|
/// Formats an event for diagnostics.
pub extend H3Event with @debug.Debug::{to_repr}

///|
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
fn Cursor::long(self : Cursor) -> Int64 {
  let mut v = 0L
  for i in 0..<8 {
    v = (v << 8) | self.data[self.at + i].to_int64()
  }
  self.at += 8
  v
}

///|
fn Cursor::blob(self : Cursor) -> BytesView {
  let len = self.long().to_int()
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
///
/// `blocks` holds the fields of header sections whose end record has not
/// come yet; it belongs to the connection, as h2's does to its session.
fn decode_events(
  data : Bytes,
  blocks : Map[Int64, Array[(String, String)]],
) -> Array[H3Event] {
  let events = []
  let cursor = { data, at: 0, }
  while cursor.at < data.length() {
    match cursor.byte() {
      1 => blocks[cursor.long()] = []
      2 => {
        let stream = cursor.long()
        let name = latin1(cursor.blob())
        let value = latin1(cursor.blob())
        match blocks.get(stream) {
          Some(fields) => fields.push((name, value))
          None => blocks[stream] = [(name, value)]
        }
      }
      3 => {
        let stream = cursor.long()
        let end_stream = cursor.long() != 0L
        let fields = blocks.get(stream).unwrap_or([])
        blocks.remove(stream)
        events.push(Headers(stream~, fields~, end_stream~))
      }
      4 => {
        let stream = cursor.long()
        events.push(Data(stream~, cursor.blob().to_owned()))
      }
      5 => events.push(EndStream(stream=cursor.long()))
      6 => {
        let stream = cursor.long()
        blocks.remove(stream)
        events.push(Closed(stream~, code=cursor.long()))
      }
      7 => events.push(GoAway(id=cursor.long()))
      9 => {
        let stream = cursor.long()
        events.push(Sent(stream~, end_stream=cursor.long() != 0L))
      }
      10 => events.push(Drained(stream=cursor.long()))
      12 => {
        let stream = cursor.long()
        blocks.remove(stream)
        events.push(TooLarge(stream~))
      }
      14 => events.push(HandshakeDone)
      15 => {
        let code = cursor.long()
        events.push(ConnectionClosed(code~, by_peer=cursor.long() != 0L))
      }
      16 => events.push(Early(stream=cursor.long()))
      17 => events.push(EarlyDataRejected)
      18 => events.push(Ticket)
      other => abort("h3_stub.c recorded an unknown event \{other}")
    }
  }
  events
}
