///|
/// TCP and TLS over portable connections. Neither write-half shutdown nor
/// ALPN negotiation is exposed by this adapter.
pub struct TcpDialer {
  priv trust : @trust.Trust
  priv refuse_internal : Bool
}

///|
/// Creates a dialer using system certificate roots unless specified otherwise.
/// `refuse_internal` defaults to false. When true, resolve once, refuse
/// internal/special-purpose destinations as Invalid/Dial, then connect the
/// exact answer. TLS still receives the original host. Every redirect dial
/// is checked. With a proxy only the proxy address is checked: the target
/// is resolved/connected by the proxy and needs a policy at that proxy.
/// Limitation: with refuse_internal, only the first resolved address is tried.
/// core/async exposes neither a complete resolved candidate set nor a
/// per-candidate validation hook for connect_to_host, so guarded dialing
/// cannot use its cross-address fallback without resolving again.
pub fn TcpDialer::new(
  trust~ : @trust.Trust = System,
  refuse_internal~ : Bool = false,
) -> TcpDialer {
  { trust, refuse_internal, }
}

///|
/// Exposes the portable Dialer operations as methods.
pub extend TcpDialer with @rt.Dialer::{connect, start_tls}

///|
fn dial_error(error : Error) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Connect, phase=Dial, detail=error.to_string())
}

///|
/// Connects to a host; TCP and name-resolution failures are Connect/Dial,
/// and a port outside 0..=65535 is Invalid/Dial.
pub impl @rt.Dialer for TcpDialer with fn connect(self, host~, port~) {
  guard port >= 0 && port <= 65535 else {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Dial,
      detail="port \{port} is outside 0..=65535",
    )
  }
  let tcp = try {
    if self.refuse_internal {
      let addr = @socket.Addr::resolve(host, port=port.to_uint16())
      if internal_address(addr) {
        raise @mttp_core.TransportError(
          kind=Invalid,
          phase=Dial,
          detail="refuse_internal: resolved address \{addr} is internal or special-purpose",
        )
      }
      // Connect this exact answer, never resolve a second time (DNS rebinding).
      @socket.Tcp::connect(addr)
    } else {
      @socket.Tcp::connect_to_host(host, port=port.to_uint16())
    }
  } catch {
    @mttp_core.TransportError(_) as error => raise error
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
  @socketconn.from_tls(tls, inner, lower_sends=() => io.sends, lower_failure=() => {
    io.failure
  })
}
