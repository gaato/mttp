// A gaato/mttp_core Backend over wasi:http@0.3.0's client.send. The host
// owns connections, TLS and HTTP versions; this file translates, bounds the
// attempt with gaato/mttp_core/attempt, and classifies error-code.

///|
pub struct WasiBackend {
  clock : &@rt.Clock
  timer : &@rt.Timer
  mut closed : Bool
  /// What the host said about request-options, for the spike's record.
  notes : Array[String]
}

///|
pub fn WasiBackend::new(clock : &@rt.Clock, timer : &@rt.Timer) -> WasiBackend {
  { clock, timer, closed: false, notes: [] }
}

///|
fn invalid(detail : String) -> @mttp.TransportError {
  @mttp.TransportError(kind=Invalid, phase=Pool, detail~)
}

///|
fn wasi_method(m : @mttp.Method) -> @http.Method {
  match m {
    Get => Get
    Head => Head
    Post => Post
    Put => Put
    Delete => Delete
    Connect => Connect
    Options => Options
    Trace => Trace
    Patch => Patch
    Other(s) => Other(s)
    other => Other(other.to_string())
  }
}

///|
/// error-code to Kind and phase. `phase` is where the attempt was: Head for
/// client.send (connect, write and head in one await), Body for a body read.
/// Only codes that can only come before any request byte are unsent (Dial
/// or Connect); a code that may also come later stays in `phase`, by
/// CONTRACT.md's rule 2.
fn classify(code : @http.ErrorCode, phase : @mttp.Phase) -> @mttp.TransportError {
  let detail = "wasi:http " + @debug.to_string(code)
  let (kind, at) : (@mttp.Kind, @mttp.Phase) = match code {
    DnsTimeout | ConnectionTimeout => (Timeout(ms=0), Dial)
    DnsError(_)
    | DestinationNotFound
    | DestinationUnavailable
    | DestinationIpProhibited
    | DestinationIpUnroutable
    | ConnectionRefused
    | TlsCertificateError => (Connect, Dial)
    ConnectionLimitReached => (Connect, Pool)
    // The WIT does not say whether these can follow the handshake.
    TlsProtocolError | TlsAlertReceived(_) => (Network, phase)
    ConnectionTerminated | HttpResponseIncomplete | InternalError(_) =>
      (Network, phase)
    ConnectionReadTimeout | HttpResponseTimeout => (Timeout(ms=0), phase)
    ConnectionWriteTimeout => (Timeout(ms=0), Write)
    HttpRequestDenied
    | HttpRequestLengthRequired
    | HttpRequestMethodInvalid
    | HttpRequestUriInvalid
    | HttpRequestUriTooLong
    | HttpRequestHeaderSectionSize(_)
    | HttpRequestHeaderSize(_)
    | ConfigurationError => (Invalid, Pool)
    HttpRequestBodySize(_)
    | HttpRequestTrailerSectionSize(_)
    | HttpRequestTrailerSize(_) => (Invalid, Write)
    HttpResponseHeaderSectionSize(n) =>
      (TooLarge(limit=n.map(x => x.reinterpret_as_int()).unwrap_or(0)), Head)
    HttpResponseHeaderSize(_) | HttpResponseTrailerSectionSize(_) | HttpResponseTrailerSize(_) =>
      (TooLarge(limit=0), phase)
    HttpResponseBodySize(_) => (TooLarge(limit=0), Body)
    HttpResponseTransferCoding(_)
    | HttpResponseContentCoding(_)
    | HttpUpgradeFailed
    | HttpProtocolError
    | LoopDetected => (Protocol, phase)
  }
  @mttp.TransportError(kind~, phase=at, detail~)
}

///|
pub impl @mttp.Backend for WasiBackend with fn close(self) {
  self.closed = true
}

///|
pub impl @mttp.Backend for WasiBackend with fn send(self, request, options) {
  if self.closed {
    raise @mttp.TransportError(kind=Closed, phase=Pool, detail="the backend is closed")
  }
  options.validate()
  request.validate()
  if options.timeout_ms is Some(ms) && ms <= 0 {
    raise @mttp.TransportError(
      kind=Timeout(ms~),
      phase=Pool,
      detail="no time left before the request",
    )
  }
  let timer = @attempt.AttemptTimer::new(self.clock, self.timer, options.timeout_ms)
  let url = @mttp.Url::parse(request.url) catch {
    _ => raise invalid("not a URL: \{request.url}")
  }
  let scheme : @http.Scheme = match url.scheme {
    Some("http") => Http
    Some("https") => Https
    _ => raise invalid("only http and https URLs: \{request.url}")
  }
  guard url.userinfo is None else {
    raise invalid("credentials in the URL; use an Authorization field")
  }
  guard url.host is Some(host) else { raise invalid("no host: \{request.url}") }
  let authority = match url.port {
    Some(p) => "\{host}:\{p}"
    None => host
  }
  let path = match url.query {
    Some(q) => url.path + "?" + q
    None => if url.path.is_empty() { "/" } else { url.path }
  }
  let entries = []
  for pair in request.headers.iter() {
    let (name, value) = pair
    entries.push((name, FixedArray::from_array(@utf8.encode(value).to_array())))
  }
  let fields = match @http.Fields::from_list(entries) {
    Ok(f) => f
    Err(e) =>
      raise invalid("the host refuses a request field: " + @debug.to_string(e))
  }
  // The request body, streamed to the host. A failure reading it is the
  // caller's, so it is kept and raised instead of the host's error.
  let body_failure : Ref[@mttp.TransportError?] = Ref(None)
  let (trailers, trailers_done) = @async-core.Future::new()
  let contents = match request.body {
    Empty => {
      ignore(trailers_done.complete(Ok(None)))
      None
    }
    Bytes(bytes) => {
      ignore(trailers_done.complete(Ok(None)))
      Some(@async-core.Stream::produce(sink => {
        ignore(sink.write_all_bytes(bytes))
        sink.close()
      }))
    }
    Stream(body) => {
      let stream = body.take()
      // Rule 3: the first read comes before anything is sent, so a failing
      // stream sends nothing.
      let first = {
        errdefer stream.close()
        timer.run(Pool, () => stream.read_some())
      }
      Some(@async-core.Stream::produce(on_unstarted_drop=() => stream.close(), sink => {
        defer stream.close()
        if first is Some(bytes) && !sink.write_all_bytes(bytes) {
          return
        }
        while first is Some(_) {
          let piece = stream.read_some() catch {
            e => {
              body_failure.val = Some(e)
              ignore(trailers_done.complete(Err(@http.ErrorCode::InternalError(Some("request body")))))
              return
            }
          }
          match piece {
            Some(bytes) => if !sink.write_all_bytes(bytes) { break }
            None => break
          }
        }
        sink.close()
        ignore(trailers_done.complete(Ok(None)))
      }))
    }
    _ => raise invalid("a request Body this backend does not know")
  }
  // The host's own limits: what is left of the attempt, for connect and the
  // first byte, so the host gives up when mttp would.
  let req_options = match timer.remaining() {
    Some(ms) => {
      let o = @http.RequestOptions::request_options()
      let ns = ms.reinterpret_as_uint64() * 1_000_000UL
      if o.set_connect_timeout(Some(ns)) is Err(e) {
        self.notes.push("set-connect-timeout: " + @debug.to_string(e))
      }
      if o.set_first_byte_timeout(Some(ns)) is Err(e) {
        self.notes.push("set-first-byte-timeout: " + @debug.to_string(e))
      }
      Some(o)
    }
    None => None
  }
  let (req, _transmitted) = @http.Request::new(fields, contents, trailers, req_options)
  ignore(req.set_method(wasi_method(request.meth)))
  ignore(req.set_scheme(Some(scheme)))
  ignore(req.set_authority(Some(authority)))
  ignore(req.set_path_with_query(Some(path)))
  let sent = timer.run(Head, () => @hclient.send(req))
  if body_failure.val is Some(e) {
    raise e
  }
  let resp = match sent {
    Ok(r) => r
    Err(code) => raise classify(code, Head)
  }
  let status = resp.get_status_code().reinterpret_as_int()
  let mut headers = @mttp.Headers::empty()
  for pair in resp.get_headers().copy_all() {
    let (name, value) = pair
    headers = headers.add(name, @utf8.decode_lossy(Bytes::from_array(value[:])))
  }
  let framing = @h1.response_framing(
    headers,
    status~,
    meth?=if request.meth is Head { Some(Head) } else { None },
  ) catch {
    _ => @h1.Framing::NoBody
  }
  let declared = match framing {
    Length(n) => Some(n)
    _ => None
  }
  let (body, _trailers) = @http.Response::consume_body(
    resp,
    @async-core.Future::ready(Ok(())),
  )
  let reader = WasiBody::{
    body,
    timer: timer.for_body(options.body),
    budget: @attempt.BodyBudget::new(@attempt.body_limit(options.body)),
    declared,
    finished: false,
  }
  @mttp.Response::new(status, headers~, body=Stream(@mttp.StreamBody::new(reader)))
}

///|
priv struct WasiBody {
  body : @async-core.Stream[Byte]
  timer : @attempt.AttemptTimer
  budget : @attempt.BodyBudget
  declared : Int64?
  mut finished : Bool
}

///|
impl @mttp.BodyStream for WasiBody with fn read_some(self) {
  if self.finished {
    return None
  }
  errdefer self.close_body()
  self.budget.check_declared(self.declared)
  let piece = self.timer.run(Body, () => self.body.read(65536)) catch {
    e => raise e
  }
  match piece {
    Some(chunk) => {
      self.budget.admit(chunk.length())
      Some(Bytes::from_array(chunk[:]))
    }
    None => {
      self.close_body()
      None
    }
  }
}

///|
fn WasiBody::close_body(self : WasiBody) -> Unit {
  if !self.finished {
    self.finished = true
    self.body.drop_sync()
  }
}

///|
impl @mttp.BodyStream for WasiBody with fn close(self) {
  self.close_body()
}

///|
pub extend WasiBackend with @mttp.Backend::{send, close}
