// The server entry of gaato/mttp_ng: HTTP/1.1, HTTP/2 and, with `h3`,
// HTTP/3 on one port.

///|
/// A TLS configuration the server cannot use, or an `h3` without one.
#derive(Debug)
pub suberror ServeError {
  /// The certificate or key, or HTTP/3 without them.
  Config(String)
  /// The TCP or UDP listener.
  Listen(@server.ListenError)
}

///|
/// Writes why serving failed.
pub impl Show for ServeError with fn output(self, logger) {
  match self {
    Config(detail) => logger.write_string("server configuration: " + detail)
    Listen(error) => logger.write_string(error.to_string())
  }
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend ServeError with Show::{output, to_string}

///|
/// Serves `handler` on `addr` (`host:port`), as `@server.serve` does, with
/// HTTP/2 and HTTP/3.
///
/// With `cert` and `key` (a PEM certificate chain, leaf first, and its
/// private key), connections are TLS, and ALPN chooses HTTP/2 or HTTP/1.1
/// (`@h2server.serve`); with `h3` too, HTTP/3 listens on the same port over
/// UDP (`@h3server.serve`), and every TCP response carries
/// `Alt-Svc: h3=":port"; ma=86400` unless the handler set its own, so that
/// clients find it. Without them, connections are cleartext HTTP/1.1, and
/// with `h2c` also HTTP/2 by prior knowledge. `limits` applies to every
/// protocol; `h2_limits` and `h3_settings` give HTTP/2's and HTTP/3's
/// streams and windows. `on_listen` hears the TCP address once both
/// listeners are bound.
///
/// Cancelling it stops it: connections of every protocol are told to go
/// away and get `limits.drain_ms` to finish what is in flight.
pub async fn serve(
  handler : @mttp_core.Handler,
  addr~ : String,
  cert? : String,
  key? : String,
  h2c~ : Bool = false,
  h3~ : Bool = false,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  h2_limits~ : @h2server.H2Limits = @h2server.H2Limits::default(),
  h3_settings~ : @h3.H3Settings = @h3.H3Settings::default(),
  auto_date~ : Bool = true,
  on_listen~ : (String) -> Unit = _ => (),
  on_error~ : (@mttp_core.TransportError) -> Unit = _ => (),
) -> Unit raise ServeError {
  let (tls, quic) = match (cert, key) {
    (Some(cert), Some(key)) => {
      let tls = @tls.ServerTls::from_pem(chain=cert, key~) catch {
        error => raise Config(error.to_string())
      }
      let quic = if h3 {
        Some(
          @h3.ServerQuic::from_pem(chain=cert, key~) catch {
            error => raise Config(error.to_string())
          },
        )
      } else {
        None
      }
      (Some(tls), quic)
    }
    (None, None) =>
      if h3 {
        raise Config("h3 needs cert and key: HTTP/3 is always TLS")
      } else {
        (None, None)
      }
    _ => raise Config("cert and key go together")
  }
  guard quic is Some(quic) else {
    @h2server.serve(
      handler,
      addr~,
      tls?,
      h2c~,
      limits~,
      h2_limits~,
      auto_date~,
      on_listen~,
      on_error~,
    ) catch {
      error => raise Listen(error)
    }
    return
  }
  // TCP first, so that a port of 0 is chosen there; UDP binds the same.
  let bound : Ref[String?] = Ref(None)
  let ready = @cond_var.Cond()
  let failure : Ref[ServeError?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let advertised = (request : @mttp_core.Request) => {
        let response = handler(request)
        match bound.val {
          Some(address) if !response.headers.contains("alt-svc") => {
            let port = address[address.rev_find(":").unwrap_or(0) + 1:]
            {
              ..response,
              headers: response.headers.add(
                "alt-svc",
                "h3=\":\{port}\"; ma=86400",
              ),
            }
          }
          _ => response
        }
      }
      @h2server.serve(
        advertised,
        addr~,
        tls?,
        limits~,
        h2_limits~,
        auto_date~,
        on_listen=address => {
          bound.val = Some(address)
          ready.broadcast()
        },
        on_error~,
      ) catch {
        error => {
          failure.val = Some(Listen(error))
          ready.broadcast()
        }
      }
    })
    while bound.val is None && failure.val is None {
      ready.wait()
    }
    guard bound.val is Some(address) else { return }
    @h3server.serve(
      handler,
      addr=address,
      quic~,
      limits~,
      settings=h3_settings,
      auto_date~,
      on_listen=_ => on_listen(address),
      on_error~,
    ) catch {
      error => failure.val = Some(Listen(error))
    }
  }) catch {
    error =>
      if failure.val is None {
        failure.val = Some(Config(error.to_string()))
      }
  }
  if failure.val is Some(error) {
    raise error
  }
}
