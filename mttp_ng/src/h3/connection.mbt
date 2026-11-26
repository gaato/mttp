// A QUIC connection carrying HTTP/3, without I/O, over ngtcp2 and nghttp3
// (h3_stub.c). The engines send and receive its datagrams on UDP and wake it
// when its timers expire.

///|
priv type Context

///|
priv type Raw

///|
#borrow(path)
extern "C" fn client_context(trust : Int32, path : Bytes) -> Context = "mttp_ng_h3_client_context"

///|
#borrow(chain, key)
extern "C" fn server_context(chain : Bytes, key : Bytes) -> Context = "mttp_ng_h3_server_context"

///|
#borrow(context)
extern "C" fn context_failed(context : Context) -> Bool = "mttp_ng_h3_context_failed"

///|
#borrow(context)
extern "C" fn context_error(context : Context) -> Bytes = "mttp_ng_h3_context_error"

///|
#borrow(context, host, local_address, remote_address, values)
extern "C" fn client_new(
  context : Context,
  host : Bytes,
  local_address : Bytes,
  remote_address : Bytes,
  values : FixedArray[Int64],
) -> Raw = "mttp_ng_h3_client_new"

///|
#borrow(context, data, local_address, remote_address, values, keys)
extern "C" fn server_new(
  context : Context,
  data : Bytes,
  local_address : Bytes,
  remote_address : Bytes,
  values : FixedArray[Int64],
  keys : Bytes,
) -> Raw = "mttp_ng_h3_server_new"

///|
extern "C" fn raw_new_keys() -> Bytes = "mttp_ng_h3_new_keys"

///|
#borrow(raw)
extern "C" fn raw_failed(raw : Raw) -> Bool = "mttp_ng_h3_failed"

///|
#borrow(raw)
extern "C" fn raw_error(raw : Raw) -> Bytes = "mttp_ng_h3_error"

///|
#borrow(raw)
extern "C" fn raw_free(raw : Raw) -> Unit = "mttp_ng_h3_free"

///|
#borrow(raw, data, from)
extern "C" fn raw_read(raw : Raw, data : Bytes, from : Bytes) -> Int32 = "mttp_ng_h3_read"

///|
#borrow(raw)
extern "C" fn raw_write(raw : Raw) -> Int32 = "mttp_ng_h3_write"

///|
#borrow(raw)
extern "C" fn raw_output(raw : Raw) -> Bytes = "mttp_ng_h3_output"

///|
#borrow(raw)
extern "C" fn raw_events(raw : Raw) -> Bytes = "mttp_ng_h3_events"

///|
#borrow(raw)
extern "C" fn raw_expiry_ms(raw : Raw) -> Int64 = "mttp_ng_h3_expiry_ms"

///|
#borrow(raw)
extern "C" fn raw_on_expiry(raw : Raw) -> Int32 = "mttp_ng_h3_on_expiry"

///|
#borrow(raw)
extern "C" fn raw_close(raw : Raw, code : Int64) -> Unit = "mttp_ng_h3_close"

///|
#borrow(raw)
extern "C" fn raw_closed(raw : Raw) -> Bool = "mttp_ng_h3_closed"

///|
#borrow(raw)
extern "C" fn raw_handshake_done(raw : Raw) -> Bool = "mttp_ng_h3_handshake_done"

///|
#borrow(raw)
extern "C" fn raw_idle_ms(raw : Raw) -> Int64 = "mttp_ng_h3_idle_ms"

///|
#borrow(raw)
extern "C" fn raw_streams_left(raw : Raw) -> Int64 = "mttp_ng_h3_streams_left"

///|
#borrow(datagram)
extern "C" fn raw_version_negotiation(datagram : Bytes) -> Bytes = "mttp_ng_h3_version_negotiation"

///|
#borrow(datagram)
extern "C" fn raw_dcid(datagram : Bytes) -> Bytes = "mttp_ng_h3_dcid"

///|
#borrow(datagram, keys)
extern "C" fn raw_stateless_reset(datagram : Bytes, keys : Bytes) -> Bytes = "mttp_ng_h3_stateless_reset"

///|
#borrow(datagram, remote, keys)
extern "C" fn raw_answer_initial(
  datagram : Bytes,
  remote : Bytes,
  validate : Bool,
  keys : Bytes,
) -> Bytes = "mttp_ng_h3_answer_initial"

///|
#borrow(raw)
extern "C" fn raw_scids(raw : Raw) -> Bytes = "mttp_ng_h3_scids"

///|
#borrow(raw)
extern "C" fn raw_remote(raw : Raw) -> Bytes = "mttp_ng_h3_remote"

///|
#borrow(raw)
extern "C" fn raw_close_datagram(raw : Raw) -> Bytes = "mttp_ng_h3_close_datagram"

///|
#borrow(raw)
extern "C" fn raw_closed_by_peer(raw : Raw) -> Bool = "mttp_ng_h3_closed_by_peer"

///|
#borrow(raw)
extern "C" fn raw_pto_ms(raw : Raw) -> Int64 = "mttp_ng_h3_pto_ms"

///|
#borrow(raw, fields)
extern "C" fn raw_submit_request(
  raw : Raw,
  fields : Bytes,
  body : Bool,
) -> Int64 = "mttp_ng_h3_submit_request"

///|
#borrow(raw, fields)
extern "C" fn raw_submit_info(
  raw : Raw,
  stream : Int64,
  fields : Bytes,
) -> Int32 = "mttp_ng_h3_submit_info"

///|
#borrow(raw, fields)
extern "C" fn raw_submit_response(
  raw : Raw,
  stream : Int64,
  fields : Bytes,
  body : Bool,
) -> Int32 = "mttp_ng_h3_submit_response"

///|
#borrow(raw, data)
extern "C" fn raw_push(
  raw : Raw,
  stream : Int64,
  data : Bytes,
  end : Bool,
) -> Int32 = "mttp_ng_h3_push"

///|
#borrow(raw)
extern "C" fn raw_queued(raw : Raw, stream : Int64) -> Int64 = "mttp_ng_h3_queued"

///|
#borrow(raw)
extern "C" fn raw_reset(
  raw : Raw,
  stream : Int64,
  code : Int64,
  read_only : Bool,
) -> Unit = "mttp_ng_h3_reset"

///|
#borrow(raw)
extern "C" fn raw_consume(raw : Raw, stream : Int64, len : Int64) -> Unit = "mttp_ng_h3_consume"

///|
#borrow(raw)
extern "C" fn raw_shutdown(raw : Raw, notice : Bool) -> Int32 = "mttp_ng_h3_shutdown"

///|
extern "C" fn strerror(code : Int32) -> Bytes = "mttp_ng_h3_strerror"

///|
/// The version number of the linked ngtcp2, as `0xMMmmpp`.
pub extern "C" fn ngtcp2_version() -> Int32 = "mttp_ng_h3_ngtcp2_version"

///|
/// The version number of the linked nghttp3, as `0xMMmmpp`.
pub extern "C" fn nghttp3_version() -> Int32 = "mttp_ng_h3_nghttp3_version"

///|
/// Initialises ngtcp2's OpenSSL crypto library; 0 on success. Contexts do
/// it themselves.
pub extern "C" fn crypto_init() -> Int32 = "mttp_ng_h3_crypto_init"

///|
/// A QUIC connection or its configuration failed: ngtcp2's or nghttp3's
/// code (0 for a configuration) and text.
#derive(Debug)
pub suberror H3Error {
  H3Error(code~ : Int32, detail~ : String)
}

///|
/// Writes the failure.
pub impl Show for H3Error with fn output(self, logger) {
  let H3Error(code~, detail~) = self
  logger.write_string("HTTP/3: \{detail} (\{code})")
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend H3Error with Show::{output, to_string}

///|
/// What a client connection trusts. Building one loads the certificate
/// roots once; every connection made from it shares them. ALPN is `h3`,
/// TLS 1.3 only (RFC 9001).
pub struct ClientQuic {
  priv context : Context
}

///|
/// A client configuration: certificates checked against `trust`, as
/// `@tls.ClientTls::new` has it.
pub fn ClientQuic::new(
  trust~ : @trust.Trust = System,
) -> ClientQuic raise H3Error {
  let context = match trust {
    System => client_context(0, b"")
    Insecure => client_context(1, b"")
    PemFile(path) => client_context(2, @utf8.encode(path))
    @trust.Trust::.. => raise H3Error(code=0, detail="unsupported trust policy")
  }
  if context_failed(context) {
    raise H3Error(code=0, detail=@utf8.decode_lossy(context_error(context)))
  }
  { context, }
}

///|
/// What a server connection presents: a PEM certificate chain (leaf first)
/// and its private key. ALPN is `h3`; no session tickets, so no 0-RTT.
pub struct ServerQuic {
  priv context : Context
}

///|
/// A server configuration.
pub fn ServerQuic::from_pem(
  chain~ : String,
  key~ : String,
) -> ServerQuic raise H3Error {
  let context = server_context(@utf8.encode(chain), @utf8.encode(key))
  if context_failed(context) {
    raise H3Error(code=0, detail=@utf8.decode_lossy(context_error(context)))
  }
  { context, }
}

///|
/// The transport parameters and bounds of a connection.
#derive(Eq, Debug)
pub(all) struct H3Settings {
  /// The request streams a client may open to a server at once (a client
  /// lets the server open none).
  max_streams_bidi : Int32
  /// What one stream may receive before its reader takes it.
  stream_window : Int32
  /// What the whole connection may receive before its readers take it.
  connection_window : Int32
  /// The largest header section taken (names, values and 32 bytes per
  /// field), also advertised as SETTINGS_MAX_FIELD_SECTION_SIZE.
  max_header_list : Int32
  /// A body queue below this many bytes records `Drained`.
  low_mark : Int32
  /// max_idle_timeout, in milliseconds.
  idle_timeout_ms : Int32
}

///|
/// Compares settings.
pub extend H3Settings with Eq::{equal, not_equal}

///|
/// Formats settings for diagnostics.
pub extend H3Settings with @debug.Debug::{to_repr}

///|
/// 100 streams, 256 KiB per stream, 1 MiB per connection, 64 KiB of header
/// section, 30 seconds of idle time.
pub fn H3Settings::default() -> H3Settings {
  {
    max_streams_bidi: 100,
    stream_window: 256 * 1024,
    connection_window: 1024 * 1024,
    max_header_list: 64 * 1024,
    low_mark: 16384,
    idle_timeout_ms: 30000,
  }
}

///|
fn values(settings : H3Settings) -> FixedArray[Int64] {
  [
    settings.max_streams_bidi.to_int64(),
    settings.stream_window.to_int64(),
    settings.connection_window.to_int64(),
    settings.max_header_list.to_int64(),
    settings.low_mark.to_int64(),
    settings.idle_timeout_ms.to_int64(),
  ]
}

///|
/// A QUIC connection with HTTP/3 on it, client or server.
pub struct QuicConn {
  priv raw : Raw
  /// Header sections begun and not yet ended, across `events` calls.
  priv blocks : Map[Int64, Array[(String, String)]]
}

///|
fn opened(raw : Raw) -> QuicConn raise H3Error {
  if raw_failed(raw) {
    let detail = @utf8.decode_lossy(raw_error(raw))
    raw_free(raw)
    raise H3Error(code=0, detail~)
  }
  { raw, blocks: Map([]), }
}

///|
/// A client connection to `host` (the name sent as SNI and checked against
/// the certificate, or an IP literal without brackets) at `remote_address`
/// (`host:port`, IPv6 in brackets), from `local_address` (by default the
/// any-address of the remote's family, enough for a connected UDP socket).
/// Its first datagrams come from the first `datagrams`.
pub fn QuicConn::client(
  quic : ClientQuic,
  host~ : String,
  local_address~ : String = "",
  remote_address~ : String,
  settings~ : H3Settings = H3Settings::default(),
) -> QuicConn raise H3Error {
  opened(
    client_new(
      quic.context,
      @utf8.encode(host),
      @utf8.encode(local_address),
      @utf8.encode(remote_address),
      values(settings),
    ),
  )
}

///|
/// The keys of one server listener: of its stateless reset tokens and its
/// Retry tokens. Every connection, reset and Retry of a listener uses the
/// listener's, and no other listener's: a listener that does not route
/// another's connections would answer a packet for one of them with the
/// reset token its client accepts, an oracle that ends any connection
/// whose ID it learns (RFC 9000, section 21.11).
pub struct ServerKeys {
  priv bytes : Bytes
}

///|
/// Fresh random keys, for a new listener. Raises when the system's random
/// source fails.
pub fn ServerKeys::new() -> ServerKeys raise H3Error {
  let bytes = raw_new_keys()
  if bytes.length() == 0 {
    raise H3Error(code=0, detail="no random bytes for the server's keys")
  }
  { bytes, }
}

///|
/// A server connection for a client's first Initial datagram, which is
/// then to be `read`, under its listener's `keys` (by default fresh ones,
/// for a connection served alone). Raises when the datagram does not start
/// a connection, or carries a Retry token these keys did not make.
pub fn QuicConn::server(
  quic : ServerQuic,
  initial : Bytes,
  local_address~ : String,
  remote_address~ : String,
  settings~ : H3Settings = H3Settings::default(),
  keys? : ServerKeys,
) -> QuicConn raise H3Error {
  let keys = match keys {
    Some(keys) => keys
    None => ServerKeys::new()
  }
  opened(
    server_new(
      quic.context,
      initial,
      @utf8.encode(local_address),
      @utf8.encode(remote_address),
      values(settings),
      keys.bytes,
    ),
  )
}

///|
fn QuicConn::failure(self : QuicConn, code : Int32) -> H3Error {
  let detail = @utf8.decode_lossy(raw_error(self.raw))
  H3Error(
    code~,
    detail=if detail.is_empty() {
      @utf8.decode_lossy(strerror(code))
    } else {
      detail
    },
  )
}

///|
/// Processes one received datagram, which came `from` an address
/// (`host:port`, IPv6 in brackets; by default the connection's first remote
/// address). A server's datagram from another address is its client's
/// migration or a NAT's rebinding, which QUIC validates before sending
/// there more than its limit allows. A failure closes the connection: its
/// CONNECTION_CLOSE waits in `datagrams`, and `closed` turns true.
pub fn QuicConn::read(
  self : QuicConn,
  datagram : Bytes,
  from? : String,
) -> Unit raise H3Error {
  let from = match from {
    Some(address) => @utf8.encode(address)
    None => b""
  }
  let code = raw_read(self.raw, datagram, from)
  if code != 0 {
    raise self.failure(code)
  }
}

///|
/// Serializes what the connection has to send now, and returns the
/// datagrams, each with the address it goes to (`host:port`, IPv6 in
/// brackets): a server's differ while its client's new path is validated.
/// Empty when it has nothing to say (or must wait, as congestion control or
/// pacing says).
pub fn QuicConn::addressed_datagrams(
  self : QuicConn,
) -> Array[(String, Bytes)] raise H3Error {
  let code = raw_write(self.raw)
  let out = raw_output(self.raw)
  let datagrams = []
  let mut at = 0
  while at + 3 <= out.length() {
    let len = (out[at].to_int() << 8) | out[at + 1].to_int()
    let textlen = out[at + 2].to_int()
    let start = at + 3 + textlen
    let address = @utf8.decode_lossy(out[at + 3:start])
    datagrams.push((address, out[start:start + len].to_owned()))
    at = start + len
  }
  if code != 0 && datagrams.is_empty() {
    raise self.failure(code)
  }
  datagrams
}

///|
/// Serializes what the connection has to send now, and returns the
/// datagrams, for a connected socket (`addressed_datagrams` says where each
/// goes); empty when it has nothing to say (or must wait, as congestion
/// control or pacing says).
pub fn QuicConn::datagrams(self : QuicConn) -> Array[Bytes] raise H3Error {
  self.addressed_datagrams().map(pair => pair.1)
}

///|
/// The connection IDs this end issued and has not retired: what the
/// peer's packets carry as their Destination Connection ID, besides the
/// one of its first Initial. A server routes datagrams by them.
pub fn QuicConn::connection_ids(self : QuicConn) -> Array[Bytes] {
  let blob = raw_scids(self.raw)
  let ids = []
  let mut at = 0
  while at < blob.length() {
    let len = blob[at].to_int()
    ids.push(blob[at + 1:at + 1 + len].to_owned())
    at += 1 + len
  }
  ids
}

///|
/// The peer's address now (`host:port`, IPv6 in brackets): a server's
/// client may have moved since its first datagram.
pub fn QuicConn::remote_address(self : QuicConn) -> String {
  @utf8.decode_lossy(raw_remote(self.raw))
}

///|
/// The CONNECTION_CLOSE datagram this end sent, for a server to send again
/// in the closing period (RFC 9000, section 10.2.1); `None` when the peer
/// closed the connection or it timed out.
pub fn QuicConn::close_datagram(self : QuicConn) -> Bytes? {
  let datagram = raw_close_datagram(self.raw)
  if datagram.length() == 0 {
    None
  } else {
    Some(datagram)
  }
}

///|
/// Whether the connection closed because the peer closed it (its
/// CONNECTION_CLOSE arrived): the draining period's case.
pub fn QuicConn::closed_by_peer(self : QuicConn) -> Bool {
  raw_closed_by_peer(self.raw)
}

///|
/// The connection's probe timeout in milliseconds (at least 1), which
/// measures its closing and draining periods (three of them).
pub fn QuicConn::pto_ms(self : QuicConn) -> Int64 {
  raw_pto_ms(self.raw)
}

///|
/// The events recorded since the last call, in order.
pub fn QuicConn::events(self : QuicConn) -> Array[H3Event] {
  decode_events(raw_events(self.raw), self.blocks)
}

///|
/// Milliseconds until the connection's timers expire (0: now), or `None`
/// when none runs.
pub fn QuicConn::expiry_ms(self : QuicConn) -> Int32? {
  let ms = raw_expiry_ms(self.raw)
  if ms < 0L {
    None
  } else if ms > 0x7fffffffL {
    Some(0x7fffffff)
  } else {
    Some(ms.to_int())
  }
}

///|
/// Handles expired timers: retransmissions, acknowledgements, the idle
/// timeout. Raises when they closed the connection.
pub fn QuicConn::on_expiry(self : QuicConn) -> Unit raise H3Error {
  let code = raw_on_expiry(self.raw)
  if code != 0 {
    raise self.failure(code)
  }
}

///|
/// Closes the connection with an application `code` (`H3_NO_ERROR` for a
/// clean close); its CONNECTION_CLOSE waits in `datagrams`.
pub fn QuicConn::close(self : QuicConn, code~ : Int64 = H3_NO_ERROR) -> Unit {
  raw_close(self.raw, code)
}

///|
/// Whether the connection closed: nothing more is read or written.
pub fn QuicConn::closed(self : QuicConn) -> Bool {
  raw_closed(self.raw)
}

///|
/// Whether the handshake completed.
pub fn QuicConn::handshake_done(self : QuicConn) -> Bool {
  raw_handshake_done(self.raw)
}

///|
/// The request streams the server lets a client connection open now (its
/// MAX_STREAMS less the streams already opened); 0 before the handshake.
pub fn QuicConn::streams_left(self : QuicConn) -> Int64 {
  raw_streams_left(self.raw)
}

///|
/// For a server: the Version Negotiation packet that answers `datagram`,
/// when it is a long header packet of a QUIC version this module does not
/// speak in a datagram large enough to start a connection (RFC 9000,
/// sections 6.1 and 14.1). `None` for anything else, which
/// `QuicConn::server` then decides on.
pub fn version_negotiation(datagram : Bytes) -> Bytes? {
  nonempty(raw_version_negotiation(datagram))
}

///|
fn nonempty(bytes : Bytes) -> Bytes? {
  if bytes.length() == 0 {
    None
  } else {
    Some(bytes)
  }
}

///|
/// For a server: the Destination Connection ID of the first packet in
/// `datagram`, reading a short header's as long as the IDs a server of this
/// module issues; `None` when there is none to read. A server finds the
/// datagram's connection by it.
pub fn destination_cid(datagram : Bytes) -> Bytes? {
  nonempty(raw_dcid(datagram))
}

///|
/// For a server: the Stateless Reset (RFC 9000, section 10.3) that answers
/// `datagram`, a short header packet for a connection the server does not
/// have (it forgot it, or restarted), so that the client learns at once
/// that the connection is gone. Smaller than `datagram` (one byte smaller
/// up to 43 bytes), so two endpoints cannot answer each other's resets for
/// ever; `None` for a long header packet or one under 22 bytes. Its token
/// is the one `keys` gave the connection ID, so a listener answers with its
/// own keys only.
pub fn stateless_reset(datagram : Bytes, keys~ : ServerKeys) -> Bytes? {
  nonempty(raw_stateless_reset(datagram, keys.bytes))
}

///|
/// For a server: what to answer a client's Initial `datagram` from
/// `remote_address` with instead of starting a connection. With
/// `validate`, a Retry, unless the Initial carries a valid Retry token, so
/// that the client proves it receives at its address before the server
/// keeps any state for it (RFC 9000, section 8.1.2); and, whatever
/// `validate`, CONNECTION_CLOSE with INVALID_TOKEN for a Retry token that
/// is not valid (expired, or for another address; section 8.1.3). Both
/// are smaller than the Initial. `None`: start the connection with
/// `QuicConn::server`, which takes a valid Retry token as the address
/// validated. The token is made and checked with the listener's `keys`.
pub fn answer_initial(
  datagram : Bytes,
  remote_address~ : String,
  validate~ : Bool,
  keys~ : ServerKeys,
) -> Bytes? {
  nonempty(
    raw_answer_initial(
      datagram,
      @utf8.encode(remote_address),
      validate,
      keys.bytes,
    ),
  )
}

///|
/// How long the connection may stay idle before its idle timeout ends it,
/// as the peer and the loss timers have it, in milliseconds.
pub fn QuicConn::idle_ms(self : QuicConn) -> Int64 {
  raw_idle_ms(self.raw)
}

///|
/// Each octet of the field as one character (ISO-8859-1).
fn encode_fields(fields : Array[(String, String)]) -> Bytes raise H3Error {
  let out = Buffer()
  out.write_int_be(fields.length())
  let octets = (text : String) => {
    out.write_int_be(text.length())
    for char in text {
      let code = char.to_int()
      guard code <= 0xff else {
        raise H3Error(
          code=0,
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
/// Opens a request stream with its header section (pseudo fields first);
/// with `body`, its data comes from `push`. Raises before the handshake
/// completed, and when the server allows no more streams now.
pub fn QuicConn::submit_request(
  self : QuicConn,
  fields : Array[(String, String)],
  body~ : Bool,
) -> Int64 raise H3Error {
  let stream = raw_submit_request(self.raw, encode_fields(fields), body)
  if stream < 0L {
    raise self.failure(stream.to_int())
  }
  stream
}

///|
/// Submits the response on `stream` (`:status` first).
pub fn QuicConn::submit_response(
  self : QuicConn,
  stream : Int64,
  fields : Array[(String, String)],
  body~ : Bool,
) -> Unit raise H3Error {
  let code = raw_submit_response(self.raw, stream, encode_fields(fields), body)
  if code != 0 {
    raise self.failure(code)
  }
}

///|
/// Submits an informational head (`:status` 1xx, such as 100 Continue) on
/// `stream`, before its response.
pub fn QuicConn::submit_info(
  self : QuicConn,
  stream : Int64,
  fields : Array[(String, String)],
) -> Unit raise H3Error {
  let code = raw_submit_info(self.raw, stream, encode_fields(fields))
  if code != 0 {
    raise self.failure(code)
  }
}

///|
/// Queues `data` for `stream`'s body, ending it with `end`.
pub fn QuicConn::push(
  self : QuicConn,
  stream : Int64,
  data : Bytes,
  end~ : Bool,
) -> Unit raise H3Error {
  if raw_push(self.raw, stream, data, end) != 0 {
    raise H3Error(code=0, detail="stream \{stream} takes no more body")
  }
}

///|
/// Bytes of `stream`'s body not yet in a packet, or `None` without a queue.
pub fn QuicConn::queued(self : QuicConn, stream : Int64) -> Int32? {
  let n = raw_queued(self.raw, stream)
  if n < 0L {
    None
  } else {
    Some(n.to_int())
  }
}

///|
/// Ends `stream` with `code`: both ways, or, with `read_only`, only what
/// the peer sends (STOP_SENDING), so a response already queued still goes.
pub fn QuicConn::reset(
  self : QuicConn,
  stream : Int64,
  code : Int64,
  read_only~ : Bool = false,
) -> Unit {
  raw_reset(self.raw, stream, code, read_only)
}

///|
/// Acknowledges `len` body bytes of `stream` that its reader took.
pub fn QuicConn::consume(self : QuicConn, stream : Int64, len : Int32) -> Unit {
  raw_consume(self.raw, stream, len.to_int64())
}

///|
/// A server's GOAWAY: with `notice`, the one that names no stream yet
/// (RFC 9114, section 5.2), then the one naming the last.
pub fn QuicConn::shutdown(
  self : QuicConn,
  notice~ : Bool,
) -> Unit raise H3Error {
  let code = raw_shutdown(self.raw, notice)
  if code != 0 {
    raise self.failure(code)
  }
}

///|
/// Frees the connection now rather than when it is collected.
pub fn QuicConn::free(self : QuicConn) -> Unit {
  raw_free(self.raw)
}
