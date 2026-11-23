///|
/// Serves HTTP/1.1 (and 1.0) requests on one accepted connection until it
/// ends, and closes it on every exit, cancellation and invalid `limits`
/// included. `conn` belongs to this call from the start.
///
/// Each request reaches `handler` with an absolute URL made of `scheme`
/// (`http` or `https`, the scheme the connection was accepted under), the
/// `Host` field and the target; an HTTP/1.0 request without `Host` uses
/// `authority`. With `peer`, the request carries it as `@mttp_core.remote_addr`;
/// with `background`, as `@mttp_core.background`, so the handler can start work
/// that outlives the response on the caller's scheduler. Without one, no
/// `background` attribute is advertised.
///
/// The engine reads heads, chunk-size lines and trailers through the
/// bounded `gaato/http/h1` codec and applies `limits` (see `ServerLimits`).
/// A head the codec refuses is answered and the connection closed: 431 for
/// a head past `max_header_bytes` or its field limit (501 when the method
/// runs past it, 414 when the target does), 400 for malformed
/// heads and request smuggling (Content-Length with Transfer-Encoding, a
/// duplicate Content-Length), 501 for an unsupported transfer coding and for
/// CONNECT, 505 for an HTTP version other than 1.x, 417 for an expectation
/// other than `100-continue`, 413 for a Content-Length past `max_body_bytes`
/// and 408 when the head does not arrive within `header_timeout_ms`. A body
/// that fails while the handler runs replaces its response with 413, 408 or
/// 400; a handler past `handler_timeout_ms` is cancelled and answered with
/// 504; a response the engine cannot write (a status outside 200 to 599,
/// an invalid field, a stream that fails at its first read) becomes 500.
/// Each of these is reported to `on_error` as a `TransportError`.
/// With `auto_date` (the default), every final response, including an error,
/// gets an IMF-fixdate from `clock` unless it already has a Date field.
/// Formatting is cached per connection and second. `100 Continue` is unchanged.
/// A 101 is the exception to that status range: an HTTP/1.1 request must
/// ask for Upgrade and its response must carry `@rt.upgrade`. The engine
/// writes its head, joins the peer reader and invokes that callback with
/// all pending bytes and the stopping probe. HTTP deadlines then end, and
/// this call retains the connection until the callback returns. Upgrade
/// requests carrying a body are refused with 400 before the handler.
///
/// `100 Continue` is sent when the handler first reads the body, never
/// before, so a handler that refuses the request does not invite the body.
/// A read failure on the connection while the handler runs cancels it; EOF
/// does not, since the peer may have closed only its sending half. After a
/// response, a body the handler left unread is drained up to
/// `drain_max_bytes`, otherwise the connection closes. `stopping` is asked
/// before each request; once it returns `true` the current response carries
/// `Connection: close`. A streamed response marked
/// `@mttp_core.close_on_shutdown` is long-lived by design: a pull of its body is
/// not bounded by `body_timeout_ms` (writes to the client still are), and
/// it asks `stopping` before each pull and, while a pull waits, every
/// 250 ms; once it returns `true` the pull is cancelled, the body closed, a
/// chunked body ended with its last chunk (a body with a Content-Length is
/// left short) and the connection closed.
///
/// Raises `ServerConfigError` for invalid `limits`, before reading anything;
/// every other failure (including a scheme other than `http` or `https`)
/// goes to `on_error`.
/// `on_response_complete` runs once for each returned HTTP response after
/// its writes, body cleanup and unread-request drain finish, including
/// failure and cancellation. Pre-handler refusals, handler timeouts and
/// successful upgrades do not call it: an upgrade retains the connection
/// until its callback ends.
/// `before_close` runs once the exchanges have ended, before the
/// connection is closed, with whether the last message written ended as its
/// framing says: `false` after a response cut short (a body delimited by
/// the close or with a Content-Length, cut at shutdown) or a write that
/// failed; `true` otherwise, also when nothing was written. A TLS adapter
/// sends close_notify there only when it is `true`, so that a client never
/// reads a body cut short as one delimited by the close (RFC 9112, section
/// 9.8). The caller bounds it and handles its failures.
///
/// ```mbt check
/// test {
///   let driver = @driver.Driver::new()
///   let coordination = @sim.SimCoordination::new(driver)
///   let (client, server) = @sim.pair(coordination)
///   driver.run(() => {
///     let task = driver.spawn(() => {
///       @h1server.serve_conn(
///         server,
///         request => {
///           @mttp_core.Response::new(
///             200,
///             body=Bytes(@mttp_core.encode_utf8(request.url)),
///           )
///         },
///         clock=@sim.SimClock::new(driver),
///         timer=@sim.SimTimer::new(driver),
///         coordination~,
///         scheme="http",
///       )
///     })
///     client.write(
///       b"GET /hello HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n",
///     )
///     let out = Buffer()
///     while client.read(max_len=4096) is Some(bytes) {
///       out.write_bytes(bytes)
///     }
///     assert_true(out.to_bytes().has_suffix(b"http://example.test/hello"))
///     ignore(task.wait())
///   })
///   assert_eq(server.closes(), 1)
/// }
/// ```
pub async fn serve_conn(
  conn : &@rt.Conn,
  handler : @mttp_core.Handler,
  clock~ : &@rt.Clock,
  timer~ : &@rt.Timer,
  coordination~ : &@rt.Coordination,
  scheme~ : String,
  limits~ : ServerLimits = ServerLimits::default(),
  auto_date~ : Bool = true,
  peer? : String,
  authority~ : String = "localhost",
  on_error~ : (@mttp_core.TransportError) -> Unit = _ => (),
  on_response_complete~ : () -> Unit = () => (),
  stopping~ : () -> Bool = () => false,
  background? : (async () -> Unit) -> Unit,
  before_close? : async (Bool) -> Unit noraise,
) -> Unit raise ServerConfigError {
  defer conn.close()
  limits.validate()
  if scheme != "http" && scheme != "https" {
    on_error(
      @mttp_core.TransportError(
        kind=Invalid,
        phase=Head,
        detail="the server scheme must be http or https",
      ),
    )
    return
  }
  let wire = Wire::new(conn, timer)
  let session = Session::{
    wire,
    clock,
    auto_date,
    date_cache: None,
    coordination,
    handler,
    limits,
    scheme,
    peer,
    authority,
    on_error,
    on_response_complete,
    stopping,
    background,
    control: @control.SessionState::new(),
    upgrade: None,
    clean: true,
  }
  session.run()
  if before_close is Some(before_close) {
    before_close(session.clean)
  }
}
