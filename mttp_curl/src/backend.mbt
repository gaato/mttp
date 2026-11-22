///|
/// gaato/mttp_core's `Backend` over libcurl: HTTP/1.1 and HTTP/2 chosen by
/// ALPN, and HTTP/3 when asked for. One exchange per `send`; redirects,
/// retries, cookies and content decoding stay with the caller.
pub struct CurlBackend {
  priv engine : Engine?
  priv mut closed : Bool
  priv version : Int32
  priv http3 : Bool
  priv trust : @trust.Trust
  priv proxy : @h1client.ProxyConfig
  priv max_age_s : Int32
  priv head_max : Int32
}

///|
/// The network over libcurl as gaato/mttp's `@mttp.backend()` has it over
/// its own engine: a `CurlBackend` under `@codings.Decompress`, so responses
/// arrive decoded and an `Accept-Encoding` is offered unless the request has
/// one. Give it to `@mttp.client(backend=...)`. The settings are
/// `CurlBackend::new`'s.
pub fn backend(
  http3~ : Bool = false,
  trust~ : @trust.Trust = System,
  proxy? : @h1client.ProxyConfig,
  max_connection_age_ms? : Int32,
) -> &@mttp_core.Backend {
  @codings.Decompress::new(
    CurlBackend::new(http3~, trust~, proxy?, max_connection_age_ms?),
  )
}

///|
/// libcurl's own version text, such as `libcurl/8.23.0 OpenSSL/3.5.3 ...`.
pub fn CurlBackend::libcurl_version() -> String {
  @utf8.decode_lossy(curl_version_bytes())
}

///|
/// Whether the linked libcurl can speak HTTP/3. `CurlBackend::new(http3=true)`
/// over one that cannot fails every send with `Invalid`.
pub fn CurlBackend::supports_http3() -> Bool {
  (curl_features() & 2) != 0
}

///|
/// `http3=true` tries HTTP/3 first for `https` URLs and falls back to TCP,
/// as libcurl's `CURL_HTTP_VERSION_3` does. `trust` chooses the certificate
/// authorities, of the origin and of an HTTPS proxy alike (`System`:
/// libcurl's default; `PemFile`: that file instead; `Insecure`: no check).
/// `proxy` defaults to the `http_proxy`, `https_proxy`, `all_proxy` and
/// `no_proxy` variables, read once here as `@mttp.backend()` reads them;
/// `@h1client.ProxyConfig::none()` turns proxies off. `max_connection_age_ms`
/// closes connections at that total age; zero or less prevents reuse.
pub fn CurlBackend::new(
  http3~ : Bool = false,
  trust~ : @trust.Trust = System,
  proxy? : @h1client.ProxyConfig,
  max_connection_age_ms? : Int32,
) -> CurlBackend {
  CurlBackend::with_version(
    if http3 {
      CURL_HTTP_VERSION_3
    } else {
      CURL_HTTP_VERSION_2TLS
    },
    http3~,
    trust~,
    proxy=proxy.unwrap_or_else(() => {
      @h1client.ProxyConfig::from_env(@env.get_env_var)
    }),
    max_connection_age_ms?,
  )
}

///|
const CURL_HTTP_VERSION_2TLS = 4

///|
const CURL_HTTP_VERSION_3 = 30

///|
/// The response head bound, as gaato/mttp_core's HTTP/1 engine has it.
const DEFAULT_HEAD_MAX = 65536

///|
fn CurlBackend::with_version(
  version : Int32,
  http3~ : Bool,
  trust~ : @trust.Trust,
  proxy~ : @h1client.ProxyConfig = @h1client.ProxyConfig::none(),
  max_connection_age_ms? : Int32,
) -> CurlBackend {
  let engine = engine_new_raw()
  {
    engine: if engine_is_null(engine) {
      None
    } else {
      Some(engine)
    },
    closed: false,
    version,
    http3,
    trust,
    proxy,
    max_age_s: match max_connection_age_ms {
      None => -1
      Some(ms) if ms <= 0 => 0
      Some(ms) => (ms + 999) / 1000
    },
    head_max: DEFAULT_HEAD_MAX,
  }
}

///|
/// Idempotent. Later sends fail with `Closed` in phase Pool; exchanges in
/// flight fail with `Closed`, and their bodies stay closable.
pub fn CurlBackend::close(self : CurlBackend) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.engine is Some(engine) {
    engine_close(engine)
  }
}

///|
/// `CurlBackend::send`.
pub impl @mttp_core.Backend for CurlBackend with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// `CurlBackend::close`.
pub impl @mttp_core.Backend for CurlBackend with fn close(self) {
  self.close()
}

///|
fn invalid(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Invalid, phase=Pool, detail~)
}

///|
/// Request fields libcurl writes itself, from the URL and the body: a
/// caller's own would contradict them, or are not allowed in HTTP/2 and
/// HTTP/3.
let curl_owned_fields : Array[String] = [
  "host", "content-length", "transfer-encoding", "connection", "keep-alive", "te",
  "upgrade", "proxy-connection", "expect",
]

///|
/// One exchange: the response once its head has arrived, its body a stream
/// that the caller reads to its end or closes. Redirects and coded bodies
/// come back as they are, and nothing is retried here, except that libcurl
/// itself sends a refused HTTP/2 or HTTP/3 stream again on a new
/// connection, up to five times; when all are refused the error is
/// `Refused`, which counts as unsent. CONNECT and protocol upgrades are
/// refused with `Invalid` before any I/O: libcurl cannot hand a connection
/// over. A request's `@mttp_core.on_phase` callback gets the points libcurl
/// shows (`Dialed`, `TlsDone` and `Pooled` once the connection is ready,
/// `Written`, `FirstByte`), in that order, before the send returns.
pub async fn CurlBackend::send(
  self : CurlBackend,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="the backend is closed",
    )
  }
  options.validate()
  request.validate()
  let (limit, idle_ms) = match options.body {
    Exchange(max_bytes~) => (Some(max_bytes), None)
    Stream(idle_ms~) => (None, idle_ms)
    @mttp_core.BodyTiming::.. =>
      raise invalid("a BodyTiming this backend does not know")
  }
  if options.timeout_ms is Some(ms) && ms <= 0 {
    raise @mttp_core.TransportError(
      kind=Timeout(ms~),
      phase=Pool,
      detail="no time left before the request",
    )
  }
  let url = @mttp_core.Url::parse(request.url) catch {
    _ => raise invalid("not a URL: \{request.url}")
  }
  guard url.scheme is Some("http" | "https") else {
    raise invalid("only http and https URLs: \{request.url}")
  }
  guard url.userinfo is None else {
    raise invalid("credentials in the URL; use an Authorization field")
  }
  match request.meth {
    Connect => raise invalid("CONNECT is not sent by this backend")
    _ => ()
  }
  if request.headers.get("upgrade") is Some(_) {
    raise invalid("protocol upgrades are not supported by this backend")
  }
  (@h1.request_framing(request.headers) |> ignore) catch {
    _ => raise invalid("conflicting or malformed framing fields")
  }
  if self.http3 && !CurlBackend::supports_http3() {
    raise invalid(
      "http3=true, but the linked libcurl has no HTTP/3: \{CurlBackend::libcurl_version()}",
    )
  }
  guard self.engine is Some(engine) else {
    raise @mttp_core.TransportError(
      kind=Connect,
      phase=Pool,
      detail="libcurl's multi handle or its thread could not start",
    )
  }
  // The request body, its first piece read before anything is sent.
  let (body_size, first, stream) = match request.body {
    Empty => (-2L, None, None)
    Bytes(bytes) => (bytes.length().to_int64(), Some(bytes), None)
    Stream(body) => {
      let stream = body.take()
      let first = {
        errdefer stream.close()
        stream.read_some()
      }
      // A stream shorter than its declared length fails in read_some:
      // gaato/mttp_core's StreamBody counts the bytes.
      (body.length().unwrap_or(-1L), first, Some(stream))
    }
    @mttp_core.Body::.. =>
      raise invalid("a request Body this backend does not know")
  }
  let nobody = request.meth is Head
  let (cainfo, insecure) = match self.trust {
    System => ("", false)
    PemFile(path) => (path, false)
    Insecure => ("", true)
    @trust.Trust::.. => raise invalid("a Trust this backend does not know")
  }
  // The proxy for the URL's scheme; NO_PROXY is matched by libcurl.
  let proxy = match url.scheme {
    Some("https") => self.proxy.https
    _ => self.proxy.http
  }
  let xfer = transfer_new_raw(
    engine,
    @utf8.encode(request.url),
    @utf8.encode(request.meth.to_string()),
    nobody,
    if body_size == -2L || nobody {
      -2L
    } else {
      body_size
    },
    self.version,
    @utf8.encode(cainfo),
    insecure,
    self.head_max,
    65536,
    self.max_age_s,
    @utf8.encode(proxy.unwrap_or("")),
    @utf8.encode(self.proxy.no_proxy),
  )
  if xfer_is_null(xfer) {
    stream.map(s => s.close()) |> ignore
    raise @mttp_core.TransportError(
      kind=Connect,
      phase=Pool,
      detail="libcurl could not make a transfer",
    )
  }
  for field in request.headers.iter() {
    let (name, value) = field
    if !curl_owned_fields.contains(name.to_lower()) {
      transfer_header(xfer, @utf8.encode("\{name}: \{value}"))
    }
  }
  // Without these lines libcurl adds `Expect: 100-continue` to uploads and
  // `Accept: */*` to every request; a backend sends what it was given.
  transfer_header(xfer, @utf8.encode("Expect:"))
  if !request.headers.contains("accept") {
    transfer_header(xfer, @utf8.encode("Accept:"))
  }
  let fd = @raw_fd.RawFd(transfer_fd(xfer)) catch {
    _ => {
      transfer_release(xfer)
      stream.map(s => s.close()) |> ignore
      raise @mttp_core.TransportError(
        kind=Connect,
        phase=Pool,
        detail="the transfer's eventfd could not join the event loop",
      )
    }
  }
  let exchange = Exchange::{ xfer, fd, released: false, }
  // Whatever ends the send before a response is returned, its exchange and
  // its request stream end with it (rules 3 and 7).
  let mut returned = false
  defer {
    if !returned {
      exchange.release()
    }
    stream.map(s => s.close()) |> ignore
  }
  match (first, stream) {
    (Some(piece), Some(_)) => transfer_push(xfer, piece, false)
    (Some(bytes), None) => transfer_push(xfer, bytes, true)
    (None, Some(_)) => transfer_push(xfer, b"", true)
    (None, None) => ()
  }
  let mut upload_done = stream is None || first is None
  let events = PhaseEvents::{
    report: request.attributes.get(@mttp_core.on_phase),
    seen: 0,
    dialed: dialed_address(url, proxy),
    tls: url.scheme is Some("https"),
  }
  transfer_start(xfer)
  let deadline = options.timeout_ms.map(ms => {
    @env.now().reinterpret_as_int64() + ms.to_int64()
  })
  for ;; {
    let state = transfer_state(xfer)
    events.observe(state)
    if (state & ST_HEAD) != 0 && !upload_done {
      // A final response before the whole body was sent: the rest is never
      // read or sent, and the unfinished transfer's connection is not used
      // again, as gaato/mttp_core's HTTP/1 client does it.
      transfer_abandon_upload(xfer)
      upload_done = true
    }
    if (state & ST_WANTS_BODY) != 0 && !upload_done {
      // `stream` is Some here: upload_done starts true without one.
      let piece = stream.unwrap().read_some()
      match piece {
        Some(bytes) => transfer_push(xfer, bytes, false)
        None => {
          transfer_push(xfer, b"", true)
          upload_done = true
        }
      }
      continue
    }
    if (state & ST_HEAD) != 0 {
      let response = self.response(exchange, options, limit, idle_ms, deadline)
      returned = true
      return response
    }
    if (state & ST_DONE) != 0 {
      raise exchange.failure(state, self.head_max)
    }
    exchange.wait(deadline, options.timeout_ms, state)
  }
}

///|
/// The response whose head has arrived.
fn CurlBackend::response(
  self : CurlBackend,
  exchange : Exchange,
  options : @mttp_core.SendOptions,
  limit : Int32?,
  idle_ms : Int32?,
  deadline : Int64?,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  ignore(self)
  let xfer = exchange.xfer
  let status = transfer_info(xfer, 0)
  let head = @utf8.decode_lossy(transfer_text(xfer, 0))
  let mut headers = @mttp_core.Headers::empty()
  for i, raw in head.split("\n").to_array() {
    let line = raw.trim_end(chars="\r")
    if i == 0 || line.is_empty() {
      continue
    }
    if line.has_prefix(" ") || line.has_prefix("\t") {
      raise @mttp_core.TransportError(
        kind=Protocol,
        phase=Head,
        detail="a folded response field line",
      )
    }
    guard line.find(":") is Some(colon) else {
      raise @mttp_core.TransportError(
        kind=Protocol,
        phase=Head,
        detail="a response field line without a colon: \{line}",
      )
    }
    headers = headers.add(
      line[:colon].to_owned(),
      line[colon + 1:].trim(chars=" \t").to_owned(),
    )
  }
  let protocol = match transfer_info(xfer, 1) {
    1 => Some("http/1.0")
    2 => Some("http/1.1")
    3 => Some("h2")
    30 => Some("h3")
    _ => None
  }
  let body = CurlBody::{
    exchange,
    limit,
    received: 0,
    // Exchange: the attempt's deadline covers the whole body too. Stream:
    // it ended with the head, and each read waits at most idle_ms.
    deadline: if limit is Some(_) {
      deadline
    } else {
      None
    },
    timeout_ms: if limit is Some(_) {
      options.timeout_ms
    } else {
      None
    },
    idle_ms,
    finished: false,
  }
  let response = @mttp_core.Response::new(
    status,
    headers~,
    body=Stream(@mttp_core.StreamBody::new(body)),
  )
  match protocol {
    Some(id) =>
      {
        ..response,
        attributes: response.attributes.put(@mttp_core.protocol, id),
      }
    None => response
  }
}

///|
/// The host and port a new connection dials: the proxy's when there is one.
fn dialed_address(url : @mttp_core.Url, proxy : String?) -> String {
  let target = match proxy {
    Some(text) => @mttp_core.Url::parse(text) catch { _ => url }
    None => url
  }
  let host = target.host.unwrap_or("")
  match target.port_or_default() {
    Some(port) => "\{host}:\{port}"
    None => host
  }
}

///|
/// Reports a send's phase events (Backend rule 13) as the transfer's state
/// bits appear, each once and in order.
priv struct PhaseEvents {
  report : ((@mttp_core.PhaseEvent) -> Unit)?
  mut seen : Int32
  dialed : String
  tls : Bool
}

///|
fn PhaseEvents::observe(self : PhaseEvents, state : Int32) -> Unit {
  guard self.report is Some(report) else { return }
  let fresh = state & (ST_PREREQ | ST_SENT | ST_FIRST_BYTE) & self.seen.lnot()
  if fresh == 0 {
    return
  }
  if (fresh & ST_PREREQ) != 0 {
    if (state & ST_NEW_CONN) != 0 {
      report(Dialed(addr=self.dialed))
      if self.tls {
        report(TlsDone)
      }
      report(Pooled(reused=false))
    } else {
      report(Pooled(reused=true))
    }
  }
  // Written only before the first response byte: after an early response
  // it is out of order, and rule 13 leaves it out.
  if (fresh & ST_SENT) != 0 && (self.seen & ST_FIRST_BYTE) == 0 {
    report(Written)
  }
  if (fresh & ST_FIRST_BYTE) != 0 {
    report(FirstByte)
  }
  self.seen = self.seen | fresh
}

///|
/// One transfer seen from MoonBit: the C handle and the descriptor its
/// thread signals.
priv struct Exchange {
  xfer : Xfer
  fd : @raw_fd.RawFd
  mut released : Bool
}

///|
/// Gives the transfer back to the thread, once.
fn Exchange::release(self : Exchange) -> Unit {
  if self.released {
    return
  }
  self.released = true
  self.fd.close()
  transfer_release(self.xfer)
}

///|
/// Waits until the thread signals a change after `state` was read, or the
/// deadline passes (a Timeout in the phase `state` shows).
async fn Exchange::wait(
  self : Exchange,
  deadline : Int64?,
  timeout_ms : Int32?,
  state : Int32,
) -> Unit raise @mttp_core.TransportError {
  let buf = FixedArray::make(8, b'\x00')
  let read = async fn() -> Unit {
    self.fd.read_into_once(buf.mut_view()) |> ignore
  }
  let woke = match deadline {
    None =>
      try {
        read()
        true
      } catch {
        _ => false
      }
    Some(at) => {
      let left = (at - @env.now().reinterpret_as_int64())
        .max(0L)
        .min(2147483647L)
        .to_int()
      (@async.with_timeout_opt(left, read) catch { _ => None }) is Some(_)
    }
  }
  if !woke {
    if deadline is Some(_) {
      raise @mttp_core.TransportError(
        kind=Timeout(ms=timeout_ms.unwrap_or(0)),
        phase=phase_of(state),
        detail="the attempt's deadline passed",
      )
    }
    raise @mttp_core.TransportError(
      kind=Network,
      phase=phase_of(state),
      detail="the transfer's eventfd failed",
    )
  }
}

///|
/// The phase an exchange in `state` has reached. Before libcurl's prereq
/// callback nothing of the request was written (rule 2).
fn phase_of(state : Int32) -> @mttp_core.Phase {
  if (state & ST_HEAD) != 0 {
    Body
  } else if (state & ST_PREREQ) == 0 {
    Dial
  } else if (state & ST_SENT) != 0 {
    Head
  } else {
    Write
  }
}

///|
/// The error for a transfer libcurl ended without a usable response.
fn Exchange::failure(
  self : Exchange,
  state : Int32,
  head_max : Int32,
) -> @mttp_core.TransportError {
  let code = transfer_info(self.xfer, 2)
  let text = @utf8.decode_lossy(transfer_text(self.xfer, 1))
  let detail = "libcurl error \{code}: \{text}"
  let phase = phase_of(state)
  if (state & ST_CLOSED) != 0 {
    return @mttp_core.TransportError(kind=Closed, phase~, detail~)
  }
  if (state & ST_HEAD_TOO_LARGE) != 0 {
    return @mttp_core.TransportError(
      kind=TooLarge(limit=head_max),
      phase=Head,
      detail="the response head is larger than \{head_max} bytes",
    )
  }
  // A proxy that refused the tunnel: nothing reached the origin.
  let connect_code = transfer_info(self.xfer, 3)
  if connect_code >= 300 || code == 97 {
    return @mttp_core.TransportError(
      kind=Proxy(status=connect_code),
      phase=Dial,
      detail~,
    )
  }
  // libcurl sends a request again by itself when a stream is refused
  // (REFUSED_STREAM, a stream above GOAWAY) or a reused connection dies
  // before any answer, up to five times; then it gives up with this text.
  // None of those attempts was processed, so the request may be sent again
  // whatever its method (rule 2's Refused). The text is the only sign.
  if code == 56 && text.contains("times before giving up") {
    return @mttp_core.TransportError(kind=Refused, phase~, detail~)
  }
  let kind : @mttp_core.Kind = match code {
    // Resolving (the proxy too), connecting, TLS and QUIC handshakes.
    5 | 6 | 7 | 35 | 58 | 60 | 77 | 96 => Connect
    28 => Timeout(ms=0)
    // Framing the peer broke.
    8 | 16 | 92 | 95 => Protocol
    _ => Network
  }
  @mttp_core.TransportError(kind~, phase~, detail~)
}

///|
/// A response body read out of the transfer's buffer.
priv struct CurlBody {
  exchange : Exchange
  limit : Int32?
  mut received : Int32
  deadline : Int64?
  timeout_ms : Int32?
  idle_ms : Int32?
  mut finished : Bool
}

///|
impl @mttp_core.BodyStream for CurlBody with fn read_some(self) {
  if self.finished || self.exchange.released {
    return None
  }
  let xfer = self.exchange.xfer
  let buf = FixedArray::make(65536, b'\x00')
  for ;; {
    // The state before the read: the thread sets DONE only after it has
    // buffered the last bytes, so a DONE read first means the read below
    // drains everything.
    let state = transfer_state(xfer)
    let n = transfer_read(xfer, buf, 65536)
    if n > 0 {
      self.received += n
      if self.limit is Some(limit) && self.received > limit {
        self.exchange.release()
        raise @mttp_core.TransportError(
          kind=TooLarge(limit~),
          phase=Body,
          detail="the response body is larger than \{limit} bytes",
        )
      }
      return Some(Bytes::from_array(buf[:n]))
    }
    if (state & ST_DONE) != 0 {
      if transfer_info(xfer, 2) == 0 {
        self.finished = true
        self.exchange.release()
        return None
      }
      let error = self.exchange.failure(state, 0)
      self.exchange.release()
      raise error
    }
    let deadline = match (self.deadline, self.idle_ms) {
      (Some(at), _) => Some(at)
      (None, Some(ms)) =>
        Some(@env.now().reinterpret_as_int64() + ms.to_int64())
      (None, None) => None
    }
    errdefer self.exchange.release()
    self.exchange.wait(
      deadline,
      match self.timeout_ms {
        Some(ms) => Some(ms)
        None => self.idle_ms
      },
      state,
    )
  }
}

///|
impl @mttp_core.BodyStream for CurlBody with fn close(self) {
  self.exchange.release()
}
