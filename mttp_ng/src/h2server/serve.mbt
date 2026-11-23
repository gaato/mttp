// The listener: gaato/mttp's serve_conns with a session that speaks HTTP/2
// or HTTP/1.1 on each connection, as TLS's ALPN or the client's first bytes
// say.

///|
/// The client connection preface (RFC 9113, section 3.4).
let preface : Bytes = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

///|
/// A connection whose first bytes were read already: they come first.
priv struct Prefixed {
  inner : &@rt.Conn
  mut pending : Bytes
}

///|
impl @rt.Conn for Prefixed with fn read(self, max_len~) {
  if self.pending.length() > 0 {
    let n = if max_len < self.pending.length() {
      max_len
    } else {
      self.pending.length()
    }
    let out = self.pending[:n].to_owned()
    self.pending = self.pending[n:].to_owned()
    return Some(out)
  }
  self.inner.read(max_len~)
}

///|
impl @rt.Conn for Prefixed with fn write(self, bytes) {
  self.inner.write(bytes)
}

///|
impl @rt.Conn for Prefixed with fn close(self) {
  self.inner.close()
}

///|
/// Reads until the bytes either begin the preface or cannot, at most
/// `ms`: whether they do, and the connection with them unread again.
/// `None` when the client sent nothing in time or went.
async fn sniff(
  conn : &@rt.Conn,
  timer : &@rt.Timer,
  ms : Int32,
) -> (Bool, &@rt.Conn)? {
  let got = Buffer()
  let mut gone = false
  let finished = timer.within(ms, () => {
    while got.length() < preface.length() {
      let so_far = got.to_bytes()
      if so_far != preface[:so_far.length()].to_owned() {
        return
      }
      match
        (conn.read(max_len=preface.length() - got.length()) catch { _ => None }) {
        Some(bytes) => got.write_bytes(bytes)
        None => {
          gone = true
          return
        }
      }
    }
  })
  let bytes = got.to_bytes()
  if gone && bytes.length() == 0 {
    return None
  }
  if !finished && bytes.length() == 0 {
    return None
  }
  let h2 = bytes.length() == preface.length() && bytes == preface
  Some((h2, Prefixed::{ inner: conn, pending: bytes, }))
}

///|
/// Serves `handler` on `addr` over HTTP/2 and HTTP/1.1, with
/// `@server.serve`'s listener, admission bound and graceful stop
/// (`@server.serve_conns`).
///
/// With `tls`, every connection is TLS: ALPN `h2` gets HTTP/2
/// (`serve_h2_conn`), `http/1.1` or none gets HTTP/1.1 (`@h1server`), both
/// under the `https` scheme. Without, connections are cleartext HTTP/1.1,
/// and with `h2c` also cleartext HTTP/2 from clients that start with its
/// preface (prior knowledge); the HTTP/1.1 `Upgrade: h2c` is not offered
/// (RFC 9113 removed it). The TLS handshake and the preface must arrive
/// within `limits.header_timeout_ms`.
///
/// At stop, an HTTP/2 connection is told to go away (GOAWAY) and its
/// streams get `limits.drain_ms` to finish, as HTTP/1.1 exchanges do.
pub async fn serve(
  handler : @mttp_core.Handler,
  addr~ : String,
  tls? : @tls.ServerTls,
  h2c~ : Bool = false,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  h2_limits~ : H2Limits = H2Limits::default(),
  auto_date~ : Bool = true,
  on_listen~ : (String) -> Unit = _ => (),
  on_error~ : (@mttp_core.TransportError) -> Unit = _ => (),
) -> Unit raise @server.ListenError {
  @server.serve_conns(
    accepted => {
      let speak_h2 = (conn : &@rt.Conn, scheme : String) => {
        serve_h2_conn(
          conn,
          handler,
          clock=accepted.clock,
          timer=accepted.timer,
          scheme~,
          limits~,
          h2_limits~,
          auto_date~,
          peer=accepted.peer,
          on_error=accepted.on_error,
          stopping=accepted.stopping,
          activity=accepted.activity,
          background=accepted.background,
          coordination=accepted.coordination,
        )
      }
      let speak_h1 = (conn : &@rt.Conn, scheme : String) => {
        serve_h1(conn, scheme, handler, accepted, limits, auto_date)
      }
      match tls {
        Some(tls) => {
          let mut session : @tls.TlsConn? = None
          ignore(
            accepted.timer.within(limits.header_timeout_ms, () => {
              session = Some(
                tls.accept(accepted.conn, coordination=accepted.coordination),
              ) catch {
                error => {
                  (accepted.on_error)(error)
                  None
                }
              }
            }),
          )
          guard session is Some(session) else { return }
          if session.alpn() == Some("h2") {
            speak_h2(session, "https")
          } else {
            speak_h1(session, "https")
          }
        }
        None if h2c =>
          match sniff(accepted.conn, accepted.timer, limits.header_timeout_ms) {
            Some((true, conn)) => speak_h2(conn, "http")
            Some((false, conn)) => speak_h1(conn, "http")
            None => ()
          }
        None => speak_h1(accepted.conn, "http")
      }
    },
    addr~,
    limits~,
    on_listen~,
    on_error~,
  )
}

///|
/// HTTP/1.1 on `conn`, as `@server.serve` runs it.
async fn serve_h1(
  conn : &@rt.Conn,
  scheme : String,
  handler : @mttp_core.Handler,
  accepted : @server.Accepted,
  limits : @h1server.ServerLimits,
  auto_date : Bool,
) -> Unit {
  let response_finished = Ref(false)
  @h1server.serve_conn(
    conn,
    request => {
      response_finished.val = false
      (accepted.activity)(true)
      handler(request)
    },
    clock=accepted.clock,
    timer=accepted.timer,
    coordination=accepted.coordination,
    scheme~,
    limits~,
    auto_date~,
    peer=accepted.peer,
    authority=accepted.authority,
    on_error=error => {
      (accepted.activity)(true)
      (accepted.on_error)(error)
    },
    on_response_complete=() => response_finished.val = true,
    stopping=() => {
      if response_finished.val {
        (accepted.activity)(false)
      }
      (accepted.stopping)()
    },
    background=accepted.background,
  ) catch {
    _ =>
      (accepted.on_error)(
        @mttp_core.TransportError(
          kind=Invalid,
          phase=Unknown,
          detail="validated server limits refused",
        ),
      )
  }
}
