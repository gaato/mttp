// TLS sessions over any `rt.Conn`, with ALPN, on the system's OpenSSL.
// core/tls has no ALPN, and HTTP/2 over TLS is chosen by ALPN alone
// (RFC 9113, section 3.2), so this package binds OpenSSL itself. The
// session lives in C over memory buffers (tls_stub.c); every read and write
// beneath goes through the `rt.Conn` it was given, so a session runs over a
// socket, a CONNECT tunnel or an in-memory pair alike.

///|
/// An SSL_CTX in a GC-managed box whose finalizer frees it.
priv type Context

///|
/// An SSL session with its memory BIOs, in a GC-managed box whose finalizer
/// frees it if `free` did not.
priv type Session

///|
#borrow(path, alpn)
extern "C" fn client_context(
  trust : Int32,
  path : Bytes,
  alpn : Bytes,
) -> Context = "mttp_ng_tls_client_context"

///|
#borrow(chain, key, alpn)
extern "C" fn server_context(
  chain : Bytes,
  key : Bytes,
  alpn : Bytes,
) -> Context = "mttp_ng_tls_server_context"

///|
#borrow(context)
extern "C" fn context_failed(context : Context) -> Bool = "mttp_ng_tls_context_failed"

///|
#borrow(context)
extern "C" fn context_error(context : Context) -> Bytes = "mttp_ng_tls_context_error"

///|
#borrow(context, host)
extern "C" fn client_session(context : Context, host : Bytes) -> Session = "mttp_ng_tls_client_session"

///|
#borrow(context)
extern "C" fn server_session(context : Context) -> Session = "mttp_ng_tls_server_session"

///|
#borrow(session)
extern "C" fn session_failed(session : Session) -> Bool = "mttp_ng_tls_session_failed"

///|
#borrow(session)
extern "C" fn session_error(session : Session) -> Bytes = "mttp_ng_tls_session_error"

///|
#borrow(session, data)
extern "C" fn feed(
  session : Session,
  data : Bytes,
  offset : Int32,
  len : Int32,
) -> Int32 = "mttp_ng_tls_feed"

///|
#borrow(session)
extern "C" fn pending(session : Session) -> Int32 = "mttp_ng_tls_pending"

///|
#borrow(session)
extern "C" fn take(session : Session) -> Bytes = "mttp_ng_tls_take"

///|
#borrow(session)
extern "C" fn handshake_step(session : Session) -> Int32 = "mttp_ng_tls_handshake"

///|
#borrow(session, out)
extern "C" fn read_step(
  session : Session,
  out : FixedArray[Byte],
  offset : Int32,
  len : Int32,
) -> Int32 = "mttp_ng_tls_read"

///|
#borrow(session, data)
extern "C" fn write_step(
  session : Session,
  data : Bytes,
  offset : Int32,
  len : Int32,
) -> Int32 = "mttp_ng_tls_write"

///|
#borrow(session)
extern "C" fn shutdown_step(session : Session) -> Unit = "mttp_ng_tls_shutdown"

///|
#borrow(session)
extern "C" fn selected_alpn(session : Session) -> Bytes = "mttp_ng_tls_alpn"

///|
#borrow(session)
extern "C" fn negotiated_version(session : Session) -> Bytes = "mttp_ng_tls_version"

///|
#borrow(session)
extern "C" fn free_session(session : Session) -> Unit = "mttp_ng_tls_free"

///|
/// The version number of the linked OpenSSL (`OpenSSL_version_num`).
pub extern "C" fn openssl_version() -> Int64 = "mttp_ng_tls_openssl_version"

// The outcomes of a step, as tls_stub.c's STEP_ constants.

///|
const STEP_DONE = 0

///|
const STEP_WANT_READ = 1

///|
const STEP_CLOSED = 2

///|
/// The most a read takes from beneath at once: one TLS record and its
/// overhead.
const RECORD_BYTES : Int32 = 16 * 1024 + 256

///|
fn text(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes)
}

///|
/// ALPN identifiers in the wire form of RFC 7301, section 3.1.
fn alpn_wire(protocols : Array[String]) -> Bytes raise TlsConfigError {
  let out = Buffer()
  for protocol in protocols {
    let id = @utf8.encode(protocol)
    guard id.length() > 0 && id.length() <= 255 else {
      raise TlsConfigError(
        "ALPN identifier \"\{protocol}\" must be 1 to 255 bytes",
      )
    }
    out.write_byte(id.length().to_byte())
    out.write_bytes(id)
  }
  out.to_bytes()
}

///|
/// A TLS configuration was refused: a certificate, key or ALPN list that
/// OpenSSL could not use.
#derive(Debug)
pub suberror TlsConfigError {
  TlsConfigError(String)
}

///|
/// Writes why the configuration was refused.
pub impl Show for TlsConfigError with fn output(self, logger) {
  let TlsConfigError(detail) = self
  logger.write_string("TLS configuration: " + detail)
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend TlsConfigError with Show::{output, to_string}

///|
/// What a client session trusts and offers. Building one loads the
/// certificate roots once; every connection made from it shares them.
pub struct ClientTls {
  priv context : Context
}

///|
/// A client configuration: certificates checked against `trust` (the
/// system's roots by default; `PemFile` reads only that file, no default
/// directory beside it), and `alpn` offered in that order (none by
/// default). TLS 1.2 or later. A configuration OpenSSL refuses, such as an
/// unreadable PEM file, makes every `connect` fail with `Connect` in phase
/// Dial, as a failed handshake does.
pub fn ClientTls::new(
  trust~ : @trust.Trust = System,
  alpn~ : Array[String] = [],
) -> ClientTls raise TlsConfigError {
  let wire = alpn_wire(alpn)
  let context = match trust {
    System => client_context(0, b"", wire)
    Insecure => client_context(1, b"", wire)
    PemFile(path) => client_context(2, @utf8.encode(path), wire)
    @trust.Trust::.. => raise TlsConfigError("unsupported trust policy")
  }
  { context, }
}

///|
/// What a server session presents and accepts.
pub struct ServerTls {
  priv context : Context
}

///|
/// A server configuration from a PEM certificate chain (leaf first) and its
/// PEM private key, choosing from `alpn` in that order (RFC 7301, section
/// 3.2: the server's preference decides). A client that offers none of them
/// gets a session without ALPN. No session tickets.
pub fn ServerTls::from_pem(
  chain~ : String,
  key~ : String,
  alpn~ : Array[String] = ["h2", "http/1.1"],
) -> ServerTls raise TlsConfigError {
  let context = server_context(
    @utf8.encode(chain),
    @utf8.encode(key),
    alpn_wire(alpn),
  )
  if context_failed(context) {
    raise TlsConfigError(text(context_error(context)))
  }
  { context, }
}

///|
/// Starts a client session for `host` over `inner` and completes its
/// handshake. `host` is a DNS name or an IP literal without brackets; a name
/// is sent as SNI, and the certificate is checked against it unless the
/// configuration trusts anything. On success the session owns `inner`; on
/// failure or cancellation the caller still does, and closes it.
///
/// A failed handshake is `Connect` in phase Dial, so nothing was sent; a
/// failure of `inner` comes as `inner` raised it.
pub async fn ClientTls::connect(
  self : ClientTls,
  inner : &@rt.Conn,
  host~ : String,
  coordination~ : &@rt.Coordination,
) -> TlsConn raise @mttp_core.TransportError {
  if context_failed(self.context) {
    raise handshake_error(text(context_error(self.context)))
  }
  let session = client_session(self.context, @utf8.encode(host))
  if session_failed(session) {
    raise handshake_error(text(session_error(session)))
  }
  TlsConn::start(inner, session, coordination)
}

///|
/// Accepts a client's session over `inner` and completes its handshake. On
/// success the session owns `inner`; on failure the caller still does.
pub async fn ServerTls::accept(
  self : ServerTls,
  inner : &@rt.Conn,
  coordination~ : &@rt.Coordination,
) -> TlsConn raise @mttp_core.TransportError {
  let session = server_session(self.context)
  if session_failed(session) {
    raise handshake_error(text(session_error(session)))
  }
  TlsConn::start(inner, session, coordination)
}

///|
fn handshake_error(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Connect, phase=Dial, detail="TLS: " + detail)
}

///|
/// Where the read half stands.
priv enum ReadEnd {
  Open
  /// close_notify arrived: every later read is EOF.
  Eof
  /// The connection beneath ended without close_notify.
  Incomplete
}

///|
/// A TLS session over an `rt.Conn`. It is itself an `rt.Conn`: one read and
/// one write may run at the same time, and what the session must send for a
/// read (a TLS 1.3 key update, an alert) is written between the caller's
/// writes, never inside one.
///
/// `close` closes the connection beneath without close_notify, since it
/// cannot wait for a write; the peer then reads `IncompleteClose`.
/// `shutdown` sends close_notify first.
pub struct TlsConn {
  priv inner : &@rt.Conn
  priv session : Session
  priv coordination : &@rt.Coordination
  priv alpn_ : String?
  priv version_ : String
  /// Whether a task is writing the session's output beneath. Only one does
  /// at a time; it writes until nothing is left, so output a step adds
  /// meanwhile goes out in the same turn.
  priv mut flushing : Bool
  /// The tasks waiting for the writer, each woken once when it ends.
  priv waiters : Array[&@rt.Signal]
  /// The failure of a write beneath that may have sent part of a record:
  /// every later write raises it, since the stream is no longer whole.
  priv mut broken : @mttp_core.TransportError?
  priv mut read_end : ReadEnd
  priv mut closed : Bool
}

///|
async fn TlsConn::start(
  inner : &@rt.Conn,
  session : Session,
  coordination : &@rt.Coordination,
) -> TlsConn raise @mttp_core.TransportError {
  let mut done = false
  // The session is freed now on failure, not when the box goes; `inner`
  // stays the caller's.
  defer (if !done { free_session(session) })
  while true {
    let outcome = handshake_step(session)
    // A failed handshake may have queued an alert; the peer learns why,
    // as far as `inner` lets it.
    let output = take(session)
    if output.length() > 0 {
      if outcome == STEP_DONE || outcome == STEP_WANT_READ {
        inner.write(output)
      } else {
        inner.write(output) catch {
          @mttp_core.TransportError(..) => ()
        }
      }
    }
    match outcome {
      STEP_DONE => break
      STEP_WANT_READ =>
        match inner.read(max_len=RECORD_BYTES) {
          Some(chunk) => ignore(feed(session, chunk, 0, chunk.length()))
          None => raise handshake_error("the peer closed during the handshake")
        }
      _ => raise handshake_error(text(session_error(session)))
    }
  }
  let alpn = selected_alpn(session)
  done = true
  {
    inner,
    session,
    coordination,
    alpn_: if alpn.length() == 0 {
      None
    } else {
      Some(text(alpn))
    },
    version_: text(negotiated_version(session)),
    flushing: false,
    waiters: [],
    broken: None,
    read_end: Open,
    closed: false,
  }
}

///|
/// The ALPN protocol the handshake chose (`"h2"`, `"http/1.1"`), or `None`
/// when the peers agreed on none.
pub fn TlsConn::alpn(self : TlsConn) -> String? {
  self.alpn_
}

///|
/// The negotiated protocol version, such as `"TLSv1.3"`.
pub fn TlsConn::version(self : TlsConn) -> String {
  self.version_
}

///|
fn closed_error() -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=Closed,
    phase=Unknown,
    detail="the TLS session is closed",
  )
}

///|
fn incomplete_error() -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=IncompleteClose,
    phase=Unknown,
    detail="the connection ended without TLS close_notify",
  )
}

///|
fn TlsConn::session_failure(self : TlsConn) -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=Protocol,
    phase=Unknown,
    detail="TLS: " + text(session_error(self.session)),
  )
}

///|
/// Writes what the session produced beneath, one writer at a time; a caller
/// that finds a writer waits for it, then writes whatever is left.
async fn TlsConn::flush(self : TlsConn) -> Unit raise @mttp_core.TransportError {
  while self.flushing {
    let signal = self.coordination.signal()
    self.waiters.push(signal)
    signal.wait()
    if self.closed {
      raise closed_error()
    }
  }
  if self.broken is Some(error) {
    raise error
  }
  self.flushing = true
  defer {
    self.flushing = false
    let waiters = self.waiters.copy()
    self.waiters.clear()
    for waiter in waiters {
      waiter.notify()
    }
  }
  while !self.closed && pending(self.session) > 0 {
    let output = take(self.session)
    // A write that does not return may have sent part of `output`, which
    // the session already counts as sent.
    let mut written = false
    defer (if !written && self.broken is None {
      self.broken = Some(
        @mttp_core.TransportError(
          kind=Network,
          phase=Unknown,
          detail="a TLS record was cut off by a cancelled write",
        ),
      )
    })
    self.inner.write(output) catch {
      @mttp_core.TransportError(..) as error => {
        written = true
        self.broken = Some(error)
        raise error
      }
    }
    written = true
  }
}

///|
/// Writes the session's own output from a read, unless a writer is at work
/// and will write it. A failure is kept for the writes; the read goes on.
async fn TlsConn::flush_for_read(self : TlsConn) -> Unit noraise {
  if !self.flushing && !self.closed && pending(self.session) > 0 {
    self.flush() catch {
      @mttp_core.TransportError(..) => ()
    }
  }
}

///|
pub impl @rt.Conn for TlsConn with fn read(self, max_len~) {
  if self.closed {
    raise closed_error()
  }
  let size = if max_len < RECORD_BYTES { max_len } else { RECORD_BYTES }
  let buffer = FixedArray::make(size, b'\x00')
  while true {
    match self.read_end {
      Eof => return None
      Incomplete => raise incomplete_error()
      Open => ()
    }
    let got = read_step(self.session, buffer, 0, size)
    if got > 0 {
      self.flush_for_read()
      return Some(Bytes::makei(got, i => buffer[i]))
    }
    match -got {
      STEP_WANT_READ => {
        self.flush_for_read()
        match self.inner.read(max_len=RECORD_BYTES) {
          Some(chunk) => ignore(feed(self.session, chunk, 0, chunk.length()))
          None => self.read_end = Incomplete
        }
      }
      STEP_CLOSED => self.read_end = Eof
      _ => {
        if self.closed {
          raise closed_error()
        }
        raise self.session_failure()
      }
    }
  } nobreak {
    None
  }
}

///|
pub impl @rt.Conn for TlsConn with fn write(self, bytes) {
  if self.closed {
    raise closed_error()
  }
  if self.broken is Some(error) {
    raise error
  }
  let mut offset = 0
  while offset < bytes.length() {
    let took = write_step(self.session, bytes, offset, bytes.length() - offset)
    if took > 0 {
      offset += took
    } else if -took == STEP_CLOSED && offset == 0 {
      // The peer shut the session down: nothing of `bytes` went out.
      raise @mttp_core.TransportError(
        kind=Closed,
        phase=Unknown,
        detail="the peer closed the TLS session",
      )
    } else {
      raise self.session_failure()
    }
  }
  self.flush()
}

///|
pub impl @rt.Conn for TlsConn with fn close(self) {
  if self.closed {
    return
  }
  self.closed = true
  self.inner.close()
  let waiters = self.waiters.copy()
  self.waiters.clear()
  for waiter in waiters {
    waiter.notify()
  }
  free_session(self.session)
}

///|
/// Sends close_notify, so the peer reads EOF rather than
/// `IncompleteClose`. The connection stays open for reading until `close`.
pub async fn TlsConn::shutdown(
  self : TlsConn,
) -> Unit raise @mttp_core.TransportError {
  if self.closed {
    raise closed_error()
  }
  shutdown_step(self.session)
  self.flush()
}

///|
/// The Conn operations as methods.
pub extend TlsConn with @rt.Conn::{read, write, close}
