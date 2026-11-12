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
/// Connects to a host; TCP and name-resolution failures are Connect/Dial.
pub impl @rt.Dialer for TcpDialer with fn connect(_, host~, port~) {
  let tcp = @socket.Tcp::connect_to_host(host, port~) catch {
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
  @socketconn.from_tls(tls, inner, lower_writes=() => io.writes)
}
