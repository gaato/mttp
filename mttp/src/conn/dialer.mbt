///|
/// TCP and TLS over portable connections. Neither write-half shutdown nor
/// ALPN negotiation is exposed by this adapter.
pub struct TcpDialer {
  priv trust : @trust.Trust
}

///|
/// Creates a dialer using system certificate roots unless specified otherwise.
pub fn TcpDialer::new(trust~ : @trust.Trust = System) -> TcpDialer {
  { trust, }
}

///|
/// Exposes the portable Dialer operations as methods.
pub extend TcpDialer with @rt.Dialer::{connect, start_tls}

///|
fn dial_error(error : Error) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Connect, phase=Dial, detail=error.to_string())
}

///|
/// A port number in the type `@socket.Tcp::connect_to_host` takes: `Int` on
/// MoonBit 0.10.20, `UInt16` on later toolchains. The parameter's type picks
/// the impl, so `connect` builds on both; each toolchain leaves the other
/// impl unused.
priv trait SocketPort {
  fn of_port(Int32) -> Self
}

///|
#warnings("-unused_value")
impl SocketPort for Int32 with fn of_port(port) {
  port
}

///|
/// `connect` refuses a port outside 0..=65535 first, so none wraps here.
#warnings("-unused_value")
impl SocketPort for UInt16 with fn of_port(port) {
  port.to_uint16()
}

///|
/// Connects to a host; TCP and name-resolution failures are Connect/Dial,
/// and a port outside 0..=65535 is Invalid/Dial.
pub impl @rt.Dialer for TcpDialer with fn connect(_, host~, port~) {
  guard port >= 0 && port <= 65535 else {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Dial,
      detail="port \{port} is outside 0..=65535",
    )
  }
  let tcp = @socket.Tcp::connect_to_host(host, port=SocketPort::of_port(port)) catch {
    error => raise dial_error(error)
  }
  @socketconn.from_tcp(tcp)
}

///|
/// On success the TLS connection owns inner. Failure and cancellation leave
/// inner with the caller, which must close it during unwind.
pub impl @rt.Dialer for TcpDialer with fn start_tls(self, inner, host~) {
  let io = ConnIo::new(inner)
  let tls = @tls.Tls::client(
    io,
    host~,
    trust=match self.trust {
      System => SystemRoot
      Insecure => NoVerification
      PemFile(path) => CustomPemFile(path)
      @trust.Trust::.. =>
        raise @mttp_core.TransportError(
          kind=Invalid,
          phase=Dial,
          detail="unsupported TLS trust policy",
        )
    },
  ) catch {
    error => raise dial_error(error)
  }
  @socketconn.from_tls(tls, inner, lower_sends=() => io.sends)
}
