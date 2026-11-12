// gaato/mttp's Backend over moonbitstack/moonfetch. A moonfetch Client
// carries the exchanges, a new one every `exchanges_per_client` sends;
// mttp's Client owns every policy, so moonfetch's own timeout, redirects,
// decompression and cookie jar are off and each `send` is one
// `Client::stream` exchange. CONTRACT.md in gaato/mttp (Backend;
// SendOptions and BodyTiming) is what this file keeps.

///|
/// The HTTP version a response arrived over: `"HTTP/1.1"`, `"HTTP/2"` or
/// `"HTTP/3"`, as moonfetch reports it. Every response of `backend()` carries
/// it in its attributes.
///
/// ```mbt nocheck
/// let version = response.attributes.get(@mttp_moonfetch.http_version)
/// ```
pub let http_version : @mttp.AttributeKey[String] = @mttp.AttributeKey::new(
  "mttp_moonfetch.http_version",
)

///|
/// The network as a `Backend`, over moonfetch: HTTP/2 when the server offers
/// it by ALPN, HTTP/1.1 otherwise, HTTP/3 over QUIC when `http3` is true, and
/// responses decompressed (gzip, deflate, br, zstd) as `@mttp_async.backend()`
/// decompresses them. It is only the I/O: give it to a `Client`, which
/// follows redirects, retries, keeps cookies and enforces deadlines.
///
/// - `http3` (default false, as in moonfetch): try QUIC first for `https`
///   origins, and fall back to TCP for an origin that does not answer on it.
///   With moonfetch 0.1.8 a larger uncompressed response body can fail
///   partway over HTTP/3.
/// - `proxy`: send every connection through this HTTP, HTTPS or SOCKS5
///   proxy (`@moonfetch.Proxy::parse("http://proxy.example:3128")`). The
///   environment's proxy variables are not read. With a proxy, `http3` is
///   ignored: moonfetch dials QUIC straight to the origin, which would go
///   around the proxy.
/// - `tls`: moontls client settings, such as the roots to trust
///   (`@tls.Client::new(@x509.Roots::pem(pem))`). By default, the Mozilla
///   root store bundled with moonbitstack/mooncred.
pub fn backend(
  http3~ : Bool = false,
  proxy? : @moonfetch.Proxy,
  tls? : @tls.Client,
) -> &@mttp.Backend {
  @codings.Decompress::new(MoonfetchBackend::new(http3~, proxy?, tls?))
}

///|
/// The sends one moonfetch Client carries before the next ones go to a new
/// one. moonfetch 0.1.8 keeps an entry for every stream an HTTP/2 or HTTP/3
/// connection opened, ended or not, until the connection closes, so a
/// connection that is never replaced grows with every request. A Client is
/// closed once it is replaced and its last response is closed; the new one
/// opens new connections, once per 1000 requests.
let exchanges_per_client : Int32 = 1000

///|
/// One moonfetch Client, the sends it took, and the responses it still owes.
priv struct Generation {
  client : @moonfetch.Client
  mut sends : Int32
  mut open : Int32
  mut retired : Bool
  mut closed : Bool
}

///|
/// Closes the client's connections. moonfetch's close empties its pool but
/// does not stop an exchange still on its way, which may dial and keep a new
/// connection afterwards, so `release` closes the client again once the
/// last exchange of a closed generation ends.
fn Generation::shut(self : Generation) -> Unit {
  self.closed = true
  self.client.close()
}

///|
/// One exchange of this generation ended: its send failed, or its response
/// was closed. A replaced or closed generation closes with its last
/// exchange.
fn Generation::release(self : Generation) -> Unit {
  self.open -= 1
  if (self.retired || self.closed) && self.open == 0 {
    self.shut()
  }
}

///|
priv struct MoonfetchBackend {
  http3 : Bool
  proxy : @moonfetch.Proxy?
  tls : @tls.Client?
  mut current : Generation?
  /// Replaced generations with responses still open, closed with the
  /// backend.
  mut retired : Array[Generation]
  mut closed : Bool
}

///|
fn MoonfetchBackend::new(
  http3~ : Bool,
  proxy? : @moonfetch.Proxy,
  tls? : @tls.Client,
) -> MoonfetchBackend {
  // moonfetch 0.1.8 tries QUIC before its proxy-aware TCP path and dials the
  // origin directly, so a proxy would be bypassed.
  {
    http3: http3 && proxy is None,
    proxy,
    tls,
    current: None,
    retired: [],
    closed: false,
  }
}

///|
/// The generation the next send takes: the current one, or a new one when
/// it has carried `exchanges_per_client` sends.
fn MoonfetchBackend::generation(
  self : MoonfetchBackend,
) -> Generation raise @mttp.TransportError {
  match self.current {
    Some(current) if current.sends < exchanges_per_client => return current
    Some(current) => {
      current.retired = true
      if current.open == 0 {
        current.shut()
      }
      self.retired = self.retired.filter(g => !g.closed)
      if !current.closed {
        self.retired.push(current)
      }
    }
    None => ()
  }
  // Only a base URL can make Client::new fail, and none is given; a failure
  // refuses the send rather than aborting the program.
  let client = @moonfetch.Client::new(
    timeout=None,
    redirects=0,
    compression=false,
    http2=true,
    http3=self.http3,
    // moonfetch keeps idle HTTP/1.1 connections without an age limit and
    // cannot tell a stale one before writing to it, so a request on a
    // connection the server had closed would fail after being sent, and mttp
    // would not retry a POST. Each HTTP/1.1 exchange takes a fresh connection
    // instead; HTTP/2 and HTTP/3 connections are still shared.
    idle=0,
    proxy?=self.proxy,
    tls?=self.tls,
  ) catch {
    e => raise invalid(@debug.to_string(e))
  }
  let next = { client, sends: 0, open: 0, retired: false, closed: false, }
  self.current = Some(next)
  next
}

///|
impl @mttp.Backend for MoonfetchBackend with fn send(self, request, options) {
  // Taken first, so every exit below closes it (CONTRACT.md, Backend rule 3).
  let upload : Upload = match request.body {
    Empty => Nothing
    Bytes(bytes) => if bytes.is_empty() { Nothing } else { Whole(bytes) }
    Stream(cell) => Pieces(cell.take(), cell.length())
    @mttp.Body::.. => Unsupported
  }
  defer (if upload is Pieces(stream, _) { stream.close() })
  if self.closed {
    raise @mttp.TransportError(kind=Closed, phase=Pool, detail="backend closed")
  }
  request.validate()
  options.validate()
  let timing : Timing = match options.body {
    Exchange(max_bytes~) => Exchange(max_bytes~)
    Stream(idle_ms~) => Stream(idle_ms~)
    // BodyTiming is #non_exhaustive: refuse a timing this backend does not
    // know rather than guess what it means (rule 9).
    @mttp.BodyTiming::.. => raise invalid("unknown body timing")
  }
  let verb = @method.Method::of(request.meth.to_string()) catch {
    _ => raise invalid("method \{request.meth.to_string()} is not supported")
  }
  check_url(request.url)
  if upload is Unsupported {
    raise invalid("unsupported request body")
  }
  let headers = outgoing_headers(request.headers)
  let lease = self.generation()
  lease.sends += 1
  lease.open += 1
  // Until the response owns it, every exit gives the exchange back: a
  // failure, the deadline, cancellation.
  let mut handed = false
  defer (if !handed { lease.release() })
  let client = lease.client
  let started = @async.now()
  let open = async fn() -> @moonfetch.Stream {
    let body = match upload {
      Nothing | Unsupported => @moonfetch.Body::Empty
      Whole(bytes) => one_piece(bytes)
      Pieces(stream, length) => streamed(stream, length)
    }
    client.stream(verb, request.url, headers~, body~, redirects=0)
  }
  let opened = try {
    match options.timeout_ms {
      None => Some(open())
      Some(ms) => @async.with_timeout_opt(ms, open)
    }
  } catch {
    e => raise failure(e, Unknown, bodiless=upload is Nothing)
  }
  guard opened is Some(stream) else {
    raise @mttp.TransportError(
      kind=Timeout(ms=options.timeout_ms.unwrap_or(0)),
      phase=Unknown,
      detail="no response head within the attempt deadline",
    )
  }
  let deadline = match (timing, options.timeout_ms) {
    (Exchange(..), Some(ms)) => Some((started + ms.to_int64(), ms))
    _ => None
  }
  let body = ResponseBody::{
    stream,
    lease,
    timing,
    deadline,
    seen: 0,
    done: false,
  }
  handed = true
  let version = stream.version()
  {
    ..@mttp.Response::new(
      stream.status(),
      headers=@mttp.Headers::of(stream.headers()),
      body=Stream(@mttp.StreamBody::new(body)),
    ),
    attributes: @mttp.Attributes::empty().put(http_version, version),
  }
}

///|
impl @mttp.Backend for MoonfetchBackend with fn close(self) {
  if !self.closed {
    self.closed = true
    if self.current is Some(current) {
      current.shut()
    }
    for generation in self.retired {
      generation.shut()
    }
    self.retired = []
  }
}

///|
/// The request body as this backend sends it.
priv enum Upload {
  Nothing
  Whole(Bytes)
  Pieces(&@mttp.BodyStream, Int64?)
  Unsupported
}

///|
fn invalid(detail : String) -> @mttp.TransportError {
  @mttp.TransportError(kind=Invalid, phase=Pool, detail~)
}

///|
/// Refuses, before any I/O, a URL moonfetch would not send: it must be
/// absolute, `http` or `https`, with a host.
fn check_url(url : String) -> Unit raise @mttp.TransportError {
  let parsed = @mttp.Url::parse(url) catch { e => raise invalid("URL: \{e}") }
  guard parsed.scheme is Some(scheme) && scheme.to_lower() is ("http" | "https") else {
    raise invalid("URL scheme is not http or https")
  }
  guard parsed.host is Some(host) && host != "" else {
    raise invalid("URL has no host")
  }
}

///|
/// The request's fields as moonfetch sends them. moonfetch frames the body
/// itself and writes Host from the URL, so a caller's Host, Content-Length
/// or Transfer-Encoding would go out a second time on HTTP/1.1; they are
/// dropped.
fn outgoing_headers(headers : @mttp.Headers) -> Array[(String, String)] {
  headers
  .iter()
  .filter(field => {
    let name = field.0.to_lower()
    !(name is ("host" | "content-length" | "transfer-encoding"))
  })
  .collect()
}

///|
/// A buffered body as one piece. A moonfetch `Bytes` body would gain a
/// default Content-Type; a source sends exactly the caller's fields.
fn one_piece(bytes : Bytes) -> @moonfetch.Body {
  let sent = Ref(false)
  Stream(
    @moonfetch.Source::sized(bytes.length().to_int64(), fn() {
      if sent.val {
        None
      } else {
        sent.val = true
        Some(bytes)
      }
    }),
  )
}

///|
/// A streamed request body. Its first piece is read here, before moonfetch
/// writes anything, so a failing stream or one falsely declared empty sends
/// nothing (rule 3).
async fn streamed(
  stream : &@mttp.BodyStream,
  length : Int64?,
) -> @moonfetch.Body raise @mttp.TransportError {
  let first = stream.read_some()
  guard first is Some(first) else { return Empty }
  let pending = Ref(Some(first))
  let step = async fn() -> Bytes? {
    match pending.val {
      Some(piece) => {
        pending.val = None
        Some(piece)
      }
      None => stream.read_some()
    }
  }
  Stream(
    match length {
      Some(n) => @moonfetch.Source::sized(n, step)
      None => @moonfetch.Source::new(step)
    },
  )
}

///|
/// What the attempt deadline covers once the head is in, from SendOptions.
priv enum Timing {
  /// The whole body inside the attempt, at most `max_bytes` from the wire.
  Exchange(max_bytes~ : Int32)
  /// Each read waits at most `idle_ms`.
  Stream(idle_ms~ : Int32?)
}

///|
priv struct ResponseBody {
  stream : @moonfetch.Stream
  /// The generation whose client carries the stream.
  lease : Generation
  timing : Timing
  /// The attempt's end in `@async.now()` milliseconds, and its length, for
  /// an Exchange with a deadline.
  deadline : (Int64, Int32)?
  mut seen : Int32
  mut done : Bool
}

///|
impl @mttp.BodyStream for ResponseBody with fn read_some(self) {
  while !self.done {
    let wait = match (self.timing, self.deadline) {
      (Stream(idle_ms~), _) => idle_ms.map(ms => (ms, ms))
      (Exchange(..), Some((end, ms))) => {
        let left = end - @async.now()
        if left <= 0L {
          @mttp.BodyStream::close(self)
          raise @mttp.TransportError(
            kind=Timeout(ms~),
            phase=Body,
            detail="the body did not arrive within the attempt deadline",
          )
        }
        Some((left.to_int(), ms))
      }
      (Exchange(..), None) => None
    }
    let next = match wait {
      None => self.next()
      Some((left, ms)) =>
        match
          (@async.with_timeout_opt(left, () => self.next()) catch {
            e => raise failure(e, Body)
          }) {
          Some(next) => next
          None => {
            @mttp.BodyStream::close(self)
            raise @mttp.TransportError(
              kind=Timeout(ms~),
              phase=Body,
              detail=if self.timing is Stream(..) {
                "no body bytes within the idle limit"
              } else {
                "the body did not arrive within the attempt deadline"
              },
            )
          }
        }
    }
    match next {
      Some(Data(bytes)) => {
        if bytes.length() == 0 {
          continue
        }
        if self.timing is Exchange(max_bytes~) &&
          bytes.length() > max_bytes - self.seen {
          @mttp.BodyStream::close(self)
          raise @mttp.TransportError(
            kind=TooLarge(limit=max_bytes),
            phase=Body,
            detail="the body exceeds the byte limit",
          )
        }
        self.seen += bytes.length()
        return Some(bytes)
      }
      Some(End(_)) | None => @mttp.BodyStream::close(self)
    }
  }
  None
}

///|
impl @mttp.BodyStream for ResponseBody with fn close(self) {
  if !self.done {
    self.done = true
    self.stream.close()
    self.lease.release()
  }
}

///|
/// The next piece from moonfetch, with its failures as TransportErrors.
async fn ResponseBody::next(
  self : ResponseBody,
) -> @moonfetch.Chunk? raise @mttp.TransportError {
  self.stream.next() catch {
    e => {
      @mttp.BodyStream::close(self)
      raise failure(e, Body)
    }
  }
}
