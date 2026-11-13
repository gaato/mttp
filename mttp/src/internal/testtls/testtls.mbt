// A TLS server session for mttp's tests. core/async made its TLS server
// test-only (moonbitlang/core#4811), so mttp keeps its own: one state machine
// here, over an engine per target that takes the ciphertext that arrived and
// room for the ciphertext to send (engine.native.mbt, engine.wasm.mbt).
//
// Only tests import this package. It runs on native Linux (OpenSSL loaded
// at run time) and on wasm under moonrun, where mttp's CI runs. macOS would
// need the dylib names runtime/openssl.c tries there. Windows has no server;
// to add one, call the Schannel functions
// moonbit's runtime exports (moonbit_rt_schannel_*, which keep no state
// shared with core's client, unlike the runtime's OpenSSL BIO method) from
// an engine.windows file, with a PKCS#12 copy of the test certificate
// (`openssl pkcs12 -export`), as core's server_for_wbtest.mbt does; moonrun
// on a Windows host likewise wants tls/connection/set_server_pfx.

///|
/// A handshake step's outcome, as moonrun's TlsState.
priv enum State {
  Completed
  WantRead
  WantWrite
  Eof
  Error
}

///|
/// What a plaintext read or write returns when the peer sent close_notify.
const TLS_CLOSED : Int32 = -2

///|
/// What a plaintext read or write returns when it needs more ciphertext, or
/// room to put ciphertext, first.
const TLS_WOULD_BLOCK : Int32 = -3

///|
/// The largest plaintext of one TLS record.
const RECORD : Int32 = 16384

///|
/// A buffer whose live bytes are `start` to `start + len`.
priv struct Window {
  buf : FixedArray[Byte]
  mut start : Int32
  mut len : Int32
}

///|
fn Window::new(capacity : Int32) -> Window {
  { buf: FixedArray::make(capacity, b'\x00'), start: 0, len: 0, }
}

///|
fn Window::end(self : Window) -> Int32 {
  self.start + self.len
}

///|
fn Window::room(self : Window) -> Int32 {
  self.buf.length() - self.end()
}

///|
fn Window::consume(self : Window, n : Int32) -> Unit {
  self.start += n
  self.len -= n
  if self.len == 0 {
    self.start = 0
  }
}

///|
/// Moves the live bytes to the front.
fn Window::compact(self : Window) -> Unit {
  if self.start > 0 {
    self.buf.blit_to(self.buf, len=self.len, src_offset=self.start)
    self.start = 0
  }
}

///|
/// Takes the live bytes out, leaving the window empty.
fn Window::take(self : Window) -> Bytes {
  let bytes = Bytes::from_array(self.buf[self.start:self.end()])
  self.start = 0
  self.len = 0
  bytes
}

///|
/// A TLS server session over a connection, for tests.
///
/// One read and one write may run at the same time, as `rt.Conn` allows.
/// `close` does not send close_notify: it drops the connection the way a
/// server that skips TLS closure does. `shutdown` first for a clean close.
struct TestTls {
  engine : Engine
  inner : &@rt.Conn
  /// Ciphertext that arrived and the engine has not taken.
  input : Window
  /// Ciphertext the engine produced and `send` has not sent.
  output : Window
  /// Sends one batch of `output` at a time, so records leave in order.
  sending : @semaphore.Semaphore
  /// Plaintext read past what the caller asked for.
  mut pending : Bytes
  mut inner_eof : Bool
  mut shut : Bool
  /// The engine was freed; nothing may call it again.
  mut freed : Bool
}

///|
fn failure(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Network, phase=Unknown, detail~)
}

///|
/// Completes a TLS server handshake over `inner` with the PEM key and
/// certificate at those paths. A failure closes `inner`.
pub async fn accept(
  inner : &@rt.Conn,
  key_file~ : String,
  cert_file~ : String,
) -> TestTls raise @mttp_core.TransportError {
  let engine = Engine::new(key_file~, cert_file~) catch {
    error => {
      inner.close()
      raise @mttp_core.TransportError(
        kind=Invalid,
        phase=Unknown,
        detail="starting a TLS server session: \{error}",
      )
    }
  }
  let self : TestTls = {
    engine,
    inner,
    input: Window::new(4 * RECORD),
    output: Window::new(4 * RECORD),
    sending: @semaphore.Semaphore(1),
    pending: b"",
    inner_eof: false,
    shut: false,
    freed: false,
  }
  errdefer self.close()
  self.handshake()
  self
}

///|
/// Records what the last engine call took and produced.
fn TestTls::after_call(self : TestTls) -> Unit {
  self.input.consume(self.engine.bytes_read())
  self.output.len += self.engine.bytes_to_write()
}

///|
/// Sends every ciphertext the engine produced, including what it still holds.
async fn TestTls::send(self : TestTls) -> Unit raise @mttp_core.TransportError {
  self.sending.acquire()
  defer self.sending.release()
  while !self.freed {
    if self.output.len > 0 {
      self.inner.write(self.output.take())
      continue
    }
    guard self.engine.wants_write() else { break }
    self.engine.drain(self.output)
    self.after_call()
  }
}

///|
/// Reads more ciphertext from the connection; false at its EOF.
async fn TestTls::fill(self : TestTls) -> Bool raise @mttp_core.TransportError {
  self.input.compact()
  guard self.input.room() > 0 else { raise failure("TLS input buffer full") }
  match self.inner.read(max_len=self.input.room()) {
    Some(bytes) => {
      let at = self.input.end()
      self.input.buf.blit_from_bytes(at, bytes, 0, bytes.length())
      self.input.len += bytes.length()
      true
    }
    None => {
      self.inner_eof = true
      false
    }
  }
}

///|
async fn TestTls::handshake(
  self : TestTls,
) -> Unit raise @mttp_core.TransportError {
  while true {
    guard !self.freed else { raise failure("TLS session closed") }
    let state = self.engine.accept(self.input, self.output)
    self.after_call()
    match state {
      Completed => {
        self.send()
        break
      }
      WantWrite => self.send()
      WantRead => {
        self.send()
        if !self.fill() {
          raise failure("the client closed the connection during the handshake")
        }
      }
      Eof => raise failure("the client ended the session during the handshake")
      Error => raise failure("TLS handshake: \{self.engine.error()}")
    }
  }
}

///|
/// Reads at most `max_len` bytes of plaintext, or `None` once the client
/// closed: with close_notify, or by closing the connection without it (the
/// server side tolerates that).
pub async fn TestTls::read(
  self : TestTls,
  max_len~ : Int32 = RECORD,
) -> Bytes? raise @mttp_core.TransportError {
  if !self.pending.is_empty() {
    let n = self.pending.length().min(max_len)
    let bytes = self.pending[:n].to_owned()
    self.pending = self.pending[n:].to_owned()
    return Some(bytes)
  }
  let plain = FixedArray::make(max_len.min(RECORD), b'\x00')
  while true {
    guard !self.freed else { return None }
    let n = self.engine.read_plain(self.input, self.output, plain)
    let progressed = self.engine.bytes_read() > 0 ||
      self.engine.bytes_to_write() > 0
    // Read the error before `send` waits: `close` may free the engine then.
    let error = if n == -1 { self.engine.error() } else { "" }
    self.after_call()
    if self.output.len > 0 || self.engine.wants_write() {
      self.send()
    }
    if n > 0 {
      return Some(Bytes::from_array(plain[:n]))
    }
    match n {
      TLS_CLOSED => return None
      TLS_WOULD_BLOCK =>
        if progressed {
          continue
        } else if self.inner_eof {
          return None
        } else {
          ignore(self.fill())
        }
      _ => raise failure("TLS read: \{error}")
    }
  }
  None
}

///|
/// Reads up to `delimiter` and returns what came before it, consuming the
/// delimiter; `None` if the client closed first.
pub async fn TestTls::read_until(
  self : TestTls,
  delimiter : Bytes,
) -> Bytes? raise @mttp_core.TransportError {
  let buffer = Buffer()
  buffer.write_bytes(self.pending)
  self.pending = b""
  while true {
    let seen = buffer.to_bytes()
    match seen.find(delimiter) {
      Some(at) => {
        self.pending = seen[at + delimiter.length():].to_owned()
        return Some(seen[:at].to_owned())
      }
      None =>
        match self.read() {
          Some(bytes) => buffer.write_bytes(bytes)
          None => {
            self.pending = seen
            return None
          }
        }
    }
  }
  None
}

///|
/// Reads exactly `n` bytes; raises if the client closed first.
pub async fn TestTls::read_exactly(
  self : TestTls,
  n : Int32,
) -> Bytes raise @mttp_core.TransportError {
  let buffer = Buffer()
  while buffer.length() < n {
    match self.read(max_len=n - buffer.length()) {
      Some(bytes) => buffer.write_bytes(bytes)
      None => raise failure("EOF after \{buffer.length()} of \{n} bytes")
    }
  }
  buffer.to_bytes()
}

///|
/// Sends `data`. After `shutdown` or `close` it raises `Closed` without
/// sending anything.
pub async fn TestTls::write(
  self : TestTls,
  data : Bytes,
) -> Unit raise @mttp_core.TransportError {
  guard !self.freed && !self.shut else {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Write,
      detail="TLS session closed",
    )
  }
  let mut offset = 0
  while offset < data.length() {
    guard !self.freed else { raise failure("TLS session closed") }
    let n = self.engine.write_plain(self.output, data, offset)
    // Read the error before `send` waits: `close` may free the engine then.
    let error = if n == -1 { self.engine.error() } else { "" }
    self.after_call()
    self.send()
    if n > 0 {
      offset += n
      continue
    }
    match n {
      TLS_WOULD_BLOCK => continue
      TLS_CLOSED => raise failure("the client closed the TLS session")
      _ => raise failure("TLS write: \{error}")
    }
  }
}

///|
/// Sends close_notify. The connection stays open until `close`.
pub async fn TestTls::shutdown(
  self : TestTls,
) -> Unit raise @mttp_core.TransportError {
  guard !self.freed && !self.shut else { return }
  self.shut = true
  if self.engine.shutdown() != 0 {
    raise failure("TLS shutdown: \{self.engine.error()}")
  }
  // moonrun hands close_notify over on the next call without raising
  // wants_write first (core's `Tls::shutdown` drains the same way).
  self.engine.drain(self.output)
  self.after_call()
  self.send()
}

///|
/// Frees the session and closes the connection, without close_notify.
/// Idempotent.
pub fn TestTls::close(self : TestTls) -> Unit {
  if !self.freed {
    self.freed = true
    self.engine.free()
  }
  self.inner.close()
}

///|
pub impl @rt.Conn for TestTls with fn read(self, max_len~) {
  TestTls::read(self, max_len~)
}

///|
pub impl @rt.Conn for TestTls with fn write(self, bytes) {
  TestTls::write(self, bytes)
}

///|
pub impl @rt.Conn for TestTls with fn close(self) {
  TestTls::close(self)
}
