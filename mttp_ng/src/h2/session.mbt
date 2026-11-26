// An HTTP/2 session without I/O over nghttp2 (h2_stub.c). The engines read
// and write the connection; a session only turns bytes into events and
// submissions into bytes.

///|
/// An nghttp2 session in a GC-managed box whose finalizer frees it if
/// `free` did not.
priv type Raw

///|
#borrow(values)
extern "C" fn session_new(server : Bool, values : FixedArray[Int32]) -> Raw = "mttp_ng_h2_session_new"

///|
#borrow(raw)
extern "C" fn session_failed(raw : Raw) -> Bool = "mttp_ng_h2_session_failed"

///|
#borrow(raw)
extern "C" fn session_free(raw : Raw) -> Unit = "mttp_ng_h2_session_free"

///|
#borrow(raw, data)
extern "C" fn raw_recv(
  raw : Raw,
  data : Bytes,
  offset : Int32,
  len : Int32,
) -> Int32 = "mttp_ng_h2_recv"

///|
#borrow(raw)
extern "C" fn raw_send(raw : Raw) -> Bytes = "mttp_ng_h2_send"

///|
#borrow(raw)
extern "C" fn raw_events(raw : Raw) -> Bytes = "mttp_ng_h2_events"

///|
#borrow(raw)
extern "C" fn raw_want_io(raw : Raw) -> Bool = "mttp_ng_h2_want_io"

///|
#borrow(raw)
extern "C" fn raw_want_read(raw : Raw) -> Bool = "mttp_ng_h2_want_read"

///|
#borrow(raw, fields)
extern "C" fn raw_submit_request(
  raw : Raw,
  fields : Bytes,
  body : Bool,
) -> Int32 = "mttp_ng_h2_submit_request"

///|
#borrow(raw, fields)
extern "C" fn raw_submit_response(
  raw : Raw,
  stream : Int32,
  fields : Bytes,
  body : Bool,
) -> Int32 = "mttp_ng_h2_submit_response"

///|
#borrow(raw, fields)
extern "C" fn raw_submit_info(
  raw : Raw,
  stream : Int32,
  fields : Bytes,
) -> Int32 = "mttp_ng_h2_submit_info"

///|
#borrow(raw, data)
extern "C" fn raw_push(
  raw : Raw,
  stream : Int32,
  data : Bytes,
  offset : Int32,
  len : Int32,
  end : Bool,
) -> Int32 = "mttp_ng_h2_push"

///|
#borrow(raw)
extern "C" fn raw_queued(raw : Raw, stream : Int32) -> Int32 = "mttp_ng_h2_queued"

///|
#borrow(raw)
extern "C" fn raw_reset(raw : Raw, stream : Int32, code : Int32) -> Int32 = "mttp_ng_h2_reset"

///|
#borrow(raw)
extern "C" fn raw_consume(raw : Raw, stream : Int32, len : Int32) -> Int32 = "mttp_ng_h2_consume"

///|
#borrow(raw)
extern "C" fn raw_goaway(raw : Raw, code : Int32) -> Int32 = "mttp_ng_h2_goaway"

///|
#borrow(raw)
extern "C" fn raw_shutdown_notice(raw : Raw) -> Int32 = "mttp_ng_h2_shutdown_notice"

///|
#borrow(raw)
extern "C" fn raw_ping(raw : Raw) -> Int32 = "mttp_ng_h2_ping"

///|
#borrow(raw)
extern "C" fn raw_remote_max_streams(raw : Raw) -> Int32 = "mttp_ng_h2_remote_max_streams"

///|
#borrow(raw)
extern "C" fn raw_can_open(raw : Raw) -> Bool = "mttp_ng_h2_can_open"

///|
extern "C" fn strerror(code : Int32) -> Bytes = "mttp_ng_h2_strerror"

///|
/// The version number of the linked nghttp2, as `0xMMmmpp`.
pub extern "C" fn nghttp2_version() -> Int32 = "mttp_ng_h2_version"

///|
/// The settings a session advertises and the bounds it keeps.
/// `H2Settings::client()` suits a client, `H2Settings::server()` a server.
#derive(Eq, Debug)
pub(all) struct H2Settings {
  /// SETTINGS_MAX_CONCURRENT_STREAMS the peer may open towards this end;
  /// 0 advertises none (a client lets no server push open any).
  max_concurrent_streams : Int32
  /// SETTINGS_INITIAL_WINDOW_SIZE: what one stream may receive before its
  /// reader takes it.
  stream_window : Int32
  /// The connection's receive window: what all streams together may
  /// buffer before the engine takes it.
  connection_window : Int32
  /// SETTINGS_MAX_FRAME_SIZE.
  max_frame_size : Int32
  /// SETTINGS_HEADER_TABLE_SIZE: the HPACK table the peer may make this end
  /// keep.
  header_table_size : Int32
  /// The largest header block taken (names, values and 32 bytes per
  /// field): a larger one resets its stream and records `TooLarge`. A
  /// server also advertises it as SETTINGS_MAX_HEADER_LIST_SIZE; a client
  /// does not, so that a server sends a large head rather than giving up
  /// on it with a reset that says nothing of why.
  max_header_list : Int32
  /// A body queue below this many bytes records `Drained`, once per push.
  low_mark : Int32
}

///|
/// Compares settings.
pub extend H2Settings with Eq::{equal, not_equal}

///|
/// Formats settings for diagnostics.
pub extend H2Settings with @debug.Debug::{to_repr}

///|
/// A client's settings: no push, 256 KiB per stream, 1 MiB per connection,
/// 64 KiB of header list.
pub fn H2Settings::client() -> H2Settings {
  {
    max_concurrent_streams: 0,
    stream_window: 256 * 1024,
    connection_window: 1024 * 1024,
    max_frame_size: 16384,
    header_table_size: 4096,
    max_header_list: 64 * 1024,
    low_mark: 16384,
  }
}

///|
/// A server's settings: 100 concurrent streams, 256 KiB per stream, 1 MiB
/// per connection, 64 KiB of header list.
pub fn H2Settings::server() -> H2Settings {
  { ..H2Settings::client(), max_concurrent_streams: 100, }
}

///|
/// A session failed: nghttp2 refused an operation or the peer broke the
/// protocol, with nghttp2's code and text.
#derive(Debug)
pub suberror H2Error {
  H2Error(code~ : Int32, detail~ : String)
}

///|
/// Writes nghttp2's text for the failure.
pub impl Show for H2Error with fn output(self, logger) {
  let H2Error(code~, detail~) = self
  logger.write_string("HTTP/2: \{detail} (\{code})")
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend H2Error with Show::{output, to_string}

///|
fn h2_error(code : Int32) -> H2Error {
  H2Error(code~, detail=@utf8.decode_lossy(strerror(code)))
}

///|
/// An HTTP/2 session, client or server, that reads and writes no
/// connection.
pub struct H2Session {
  priv raw : Raw
  priv server : Bool
  /// Header blocks begun and not yet ended, across `events` calls.
  priv blocks : Map[Int32, Array[(String, String)]]
}

///|
fn H2Session::new(
  server : Bool,
  settings : H2Settings,
) -> H2Session raise H2Error {
  let values : FixedArray[Int32] = [
    settings.max_concurrent_streams,
    settings.stream_window,
    settings.connection_window,
    settings.max_frame_size,
    settings.header_table_size,
    settings.max_header_list,
    settings.low_mark,
  ]
  let raw = session_new(server, values)
  if session_failed(raw) {
    raise H2Error(code=-901, detail="cannot create an nghttp2 session")
  }
  { raw, server, blocks: Map([]), }
}

///|
/// A client session. Its connection preface and SETTINGS are the first
/// `output`.
pub fn H2Session::client(
  settings~ : H2Settings = H2Settings::client(),
) -> H2Session raise H2Error {
  H2Session::new(false, settings)
}

///|
/// A server session. It expects the client's connection preface first, and
/// its SETTINGS are the first `output`.
pub fn H2Session::server(
  settings~ : H2Settings = H2Settings::server(),
) -> H2Session raise H2Error {
  H2Session::new(true, settings)
}

///|
/// Whether this is a server session.
pub fn H2Session::is_server(self : H2Session) -> Bool {
  self.server
}

///|
/// Processes bytes read from the connection; the events they caused wait
/// in `events`. A protocol error is fatal: the session then queues a GOAWAY
/// in `output` and refuses everything else.
pub fn H2Session::recv(self : H2Session, data : Bytes) -> Unit raise H2Error {
  let code = raw_recv(self.raw, data, 0, data.length())
  if code != 0 {
    raise h2_error(code)
  }
}

///|
/// The bytes to write to the connection now, possibly none.
pub fn H2Session::output(self : H2Session) -> Bytes {
  raw_send(self.raw)
}

///|
/// The events recorded since the last call, in order.
pub fn H2Session::events(self : H2Session) -> Array[H2Event] {
  decode_events(raw_events(self.raw), self.blocks)
}

///|
/// Whether the session still reads or writes: false once GOAWAY went both
/// ways and every stream closed, or after a fatal error.
pub fn H2Session::wants_io(self : H2Session) -> Bool {
  raw_want_io(self.raw)
}

///|
/// Whether the session still reads: false after a connection error nghttp2
/// answered with GOAWAY itself (it does not make `recv` raise), and once a
/// GOAWAY either way left no stream to finish. The connection then only has
/// `output` left to write before it closes.
pub fn H2Session::wants_read(self : H2Session) -> Bool {
  raw_want_read(self.raw)
}

///|
/// Each octet of the field as one character (ISO-8859-1), as the h1 codec
/// does; a character above U+00FF cannot be sent.
fn encode_fields(fields : Array[(String, String)]) -> Bytes raise H2Error {
  let out = Buffer()
  out.write_int_be(fields.length())
  let octets = (text : String) => {
    out.write_int_be(text.length())
    for char in text {
      let code = char.to_int()
      guard code <= 0xff else {
        raise H2Error(
          code=-902,
          detail="a header field has a character above U+00FF",
        )
      }
      out.write_byte(code.to_byte())
    }
  }
  for field in fields {
    octets(field.0)
    octets(field.1)
  }
  out.to_bytes()
}

///|
/// Submits a request: its pseudo-header fields first (`:method`,
/// `:scheme`, `:authority`, `:path`), then the rest with lowercase names.
/// With `body`, the request's data comes from `push`; without, its HEADERS
/// frame ends the stream. Returns the stream identifier. Raises once the
/// session may open no stream (`can_open`).
pub fn H2Session::submit_request(
  self : H2Session,
  fields : Array[(String, String)],
  body~ : Bool,
) -> Int32 raise H2Error {
  let stream = raw_submit_request(self.raw, encode_fields(fields), body)
  if stream < 0 {
    raise h2_error(stream)
  }
  stream
}

///|
/// Submits the response on `stream`: `:status` first, then the rest with
/// lowercase names.
pub fn H2Session::submit_response(
  self : H2Session,
  stream : Int32,
  fields : Array[(String, String)],
  body~ : Bool,
) -> Unit raise H2Error {
  let code = raw_submit_response(self.raw, stream, encode_fields(fields), body)
  if code != 0 {
    raise h2_error(code)
  }
}

///|
/// Submits an informational head (`:status` 1xx, such as 100 Continue) on
/// `stream`, before its response.
pub fn H2Session::submit_info(
  self : H2Session,
  stream : Int32,
  fields : Array[(String, String)],
) -> Unit raise H2Error {
  let code = raw_submit_info(self.raw, stream, encode_fields(fields))
  if code != 0 {
    raise h2_error(code)
  }
}

///|
/// Queues `data` for `stream`'s body, ending it with `end`. Raises when the
/// stream takes no more: it was submitted without a body, its body already
/// ended, or it closed.
pub fn H2Session::push(
  self : H2Session,
  stream : Int32,
  data : Bytes,
  end~ : Bool,
) -> Unit raise H2Error {
  if raw_push(self.raw, stream, data, 0, data.length(), end) != 0 {
    raise H2Error(code=-903, detail="stream \{stream} takes no more body")
  }
}

///|
/// How many bytes of `stream`'s body wait to be sent: `Some(0)` once an
/// ended body went out, `None` when the stream has no queue (submitted
/// without a body, or closed).
pub fn H2Session::queued(self : H2Session, stream : Int32) -> Int32? {
  let n = raw_queued(self.raw, stream)
  if n < 0 {
    None
  } else {
    Some(n)
  }
}

///|
/// Resets `stream` with `code` (RST_STREAM).
pub fn H2Session::reset(
  self : H2Session,
  stream : Int32,
  code : ErrorCode,
) -> Unit raise H2Error {
  let rv = raw_reset(self.raw, stream, code.to_int())
  if rv != 0 {
    raise h2_error(rv)
  }
}

///|
/// Acknowledges `len` received bytes of the connection's window, which the
/// engine took into its buffers.
pub fn H2Session::consume_connection(self : H2Session, len : Int32) -> Unit {
  ignore(raw_consume(self.raw, 0, len))
}

///|
/// Acknowledges `len` received bytes of `stream`'s window, which its reader
/// took.
pub fn H2Session::consume_stream(
  self : H2Session,
  stream : Int32,
  len : Int32,
) -> Unit {
  ignore(raw_consume(self.raw, stream, len))
}

///|
/// Sends GOAWAY with `code`, naming the last stream this end processed.
pub fn H2Session::goaway(
  self : H2Session,
  code : ErrorCode,
) -> Unit raise H2Error {
  let rv = raw_goaway(self.raw, code.to_int())
  if rv != 0 {
    raise h2_error(rv)
  }
}

///|
/// A server's notice of a graceful shutdown: a GOAWAY that names the
/// highest stream identifier, so requests already on their way still
/// start; `goaway` follows with the real last stream.
pub fn H2Session::shutdown_notice(self : H2Session) -> Unit raise H2Error {
  let rv = raw_shutdown_notice(self.raw)
  if rv != 0 {
    raise h2_error(rv)
  }
}

///|
/// Sends a PING; its acknowledgement comes as `PingAck`.
pub fn H2Session::ping(self : H2Session) -> Unit raise H2Error {
  let rv = raw_ping(self.raw)
  if rv != 0 {
    raise h2_error(rv)
  }
}

///|
/// The peer's SETTINGS_MAX_CONCURRENT_STREAMS: nghttp2 assumes 100 until
/// the peer's SETTINGS arrive, and an unbounded limit reads as
/// 2147483647.
pub fn H2Session::peer_max_streams(self : H2Session) -> Int32 {
  raw_remote_max_streams(self.raw)
}

///|
/// Whether a client session may still open a stream: false after a GOAWAY
/// either way or a fatal error.
pub fn H2Session::can_open(self : H2Session) -> Bool {
  raw_can_open(self.raw)
}

///|
/// Frees the session now rather than when it is collected. Every later
/// operation fails or does nothing.
pub fn H2Session::free(self : H2Session) -> Unit {
  session_free(self.raw)
}
