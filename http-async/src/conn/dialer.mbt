///|
/// TLS peer verification. System roots are the default. PemFile replaces
/// system roots with exactly the supplied certificates. To trust system and
/// private roots together, supply a PEM bundle containing both. Insecure
/// disables certificate verification.
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum Trust {
  System
  Insecure
  PemFile(String)
}

///|
/// Compares certificate trust policies.
pub extend Trust with Eq::{equal, not_equal}

///|
/// Formats a certificate trust policy for diagnostics.
pub extend Trust with @debug.Debug::{to_repr}

///|
/// TCP and TLS over portable connections. Neither write-half shutdown nor
/// ALPN negotiation is exposed by this adapter.
pub struct TcpDialer {
  priv trust : Trust
}

///|
/// Creates a dialer using system certificate roots unless specified otherwise.
pub fn TcpDialer::new(trust~ : Trust = System) -> TcpDialer {
  { trust, }
}

///|
/// Exposes the portable Dialer operations as methods.
pub extend TcpDialer with @rt.Dialer::{connect, start_tls}

///|
fn dial_error(error : Error) -> @http.TransportError {
  @http.TransportError(kind=Connect, phase=Dial, detail=error.to_string())
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
  let tls = @tls.Tls::client(
    ConnIo::new(inner),
    host~,
    trust=match self.trust {
      System => SystemRoot
      Insecure => NoVerification
      PemFile(path) => CustomPemFile(path)
    },
  ) catch {
    error => raise dial_error(error)
  }
  @socketconn.from_tls(tls, inner)
}
