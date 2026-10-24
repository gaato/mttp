// core-main variant: every public signature below must be identical (modulo
// package paths) to the 0.22.5 variant in ../../../../v0225/src/net/net.mbt.

///|
fn tx(kind : @model.Kind, phase : @model.Phase, detail : String) -> @model.TransportError {
  @model.TransportError::TransportError(kind~, phase~, detail~)
}

///|
fn classify(phase : @model.Phase, e : Error) -> @model.TransportError {
  match e {
    @model.TransportError::TransportError(..) as t => t
    @ahttp.UriParseError::InvalidFormat => tx(Invalid, phase, "invalid URL")
    @ahttp.UriParseError::UnsupportedProtocol(p) =>
      tx(Invalid, phase, "unsupported protocol " + p)
    @ahttp.HttpProtocolError::BadRequest
    | @ahttp.HttpProtocolError::HttpVersionNotSupported(_)
    | @ahttp.HttpProtocolError::NotImplemented => tx(Protocol, phase, "malformed")
    _ =>
      match phase {
        Dial | Pool => tx(Connect, phase, e.to_string())
        _ => tx(Network, phase, e.to_string())
      }
  }
}

///|
pub struct AsyncBackend {
  priv timeout_ms : Int
}

///|
pub fn AsyncBackend::new(timeout_ms? : Int = 30000) -> AsyncBackend {
  { timeout_ms, }
}

///|
fn split_url(url : String) -> (String, String) raise @model.TransportError {
  guard url.find("://") is Some(i) else {
    raise tx(Invalid, Unknown, "not an absolute URL")
  }
  let rest = url[i + 3:]
  match rest.find("/") {
    None => (url, "/")
    Some(s) => (url[:i + 3 + s].to_owned(), rest[s:].to_owned())
  }
}

///|
fn method_of(m : String) -> @ahttp.RequestMethod raise @model.TransportError {
  match m.to_upper() {
    "GET" => Get
    "HEAD" => Head
    "POST" => Post
    "PUT" => Put
    "DELETE" => Delete
    "OPTIONS" => Options
    "PATCH" => Patch
    _ => raise tx(Invalid, Unknown, "method " + m)
  }
}

///|
priv struct ClientStream {
  client : @ahttp.Client
  buf : FixedArray[Byte]
  mut done : Bool
}

///|
impl @model.BodyStream for ClientStream with read_some(self) {
  if self.done {
    return None
  }
  // core-main: `read()` has no max_len; `read_into` keeps the 64 KiB slice.
  let n = self.client.read_into(self.buf, max_len=65536) catch {
    e => {
      self.done = true
      self.client.close()
      raise classify(Body, e)
    }
  }
  if n == 0 {
    self.done = true
    self.client.close()
    None
  } else {
    Some(Bytes::from_fixedarray(self.buf, len=n))
  }
}

///|
impl @model.BodyStream for ClientStream with close(self) {
  if !self.done {
    self.done = true
    self.client.close()
  }
}

///|
/// Single-send backend: returns once the head arrives; the body is a stream.
pub async fn AsyncBackend::send(
  self : AsyncBackend,
  req : @model.Request,
) -> @model.Response raise @model.TransportError {
  let (origin, path) = split_url(req.url)
  let meth = method_of(req.meth)
  let wire : @ahttp.Headers = Map([])
  for pair in req.headers.iter() {
    let (k, v) = pair
    let key = @ahttp.CaseInsensitiveString(k)
    wire[key] = match wire.get(key) {
      None => v
      Some(p) => p + ", " + v
    }
  }
  if req.body is Bytes(b) {
    // As http-async: declare the length, else the runtime sends chunked.
    wire[@ahttp.CaseInsensitiveString("Content-Length")] = b.length().to_string()
  }
  let opened = @async.with_timeout_opt(self.timeout_ms, () => {
    let client = @ahttp.Client(origin) catch { e => raise classify(Dial, e) }
    errdefer client.close()
    client.request(meth, path, extra_headers=wire) catch {
      e => raise classify(Write, e)
    }
    match req.body {
      Empty => ()
      Bytes(b) => client.write(b) catch { e => raise classify(Write, e) }
      Stream(s, ..) => {
        defer s.close()
        while s.read_some() is Some(chunk) {
          client.write(chunk) catch { e => raise classify(Write, e) }
        }
      }
    }
    let resp = client.end_request() catch { e => raise classify(Head, e) }
    (client, resp)
  }) catch {
    e => raise classify(Unknown, e)
  }
  guard opened is Some((client, resp)) else {
    raise tx(Timeout(ms=self.timeout_ms), Head, "timed out")
  }
  let pairs = []
  for k, v in resp.headers {
    pairs.push((k.to_string(), v))
  }
  for c in resp.cookies {
    pairs.push(("set-cookie", c.name + "=" + c.value))
  }
  {
    status: resp.code,
    headers: @model.Headers::of(pairs),
    body: Stream(ClientStream::{ client, buf: FixedArray::make(65536, 0), done: false }, length=None),
  }
}

///|
pub(all) struct ServerLimits {
  max_header_bytes : Int
  header_timeout_ms : Int
  max_body_bytes : Int
  max_connections : Int
  prescan_head : Bool
}

///|
pub fn ServerLimits::default() -> ServerLimits {
  {
    max_header_bytes: 16384,
    header_timeout_ms: 5000,
    max_body_bytes: 1048576,
    max_connections: 256,
    prescan_head: true,
  }
}

///|
pub(all) suberror ServerConfigError {
  InvalidMaxConnections(value~ : Int)
  Bind(detail~ : String)
} derive(@debug.Debug)

///|
/// core-main only: Tcp has peek_at_least, so the head can be bounded before
/// the runtime parser sees it. Returns the head length.
async fn prescan(tcp : @socket.Tcp, max : Int) -> Int? raise @model.TransportError {
  let mut need = 1
  for ;; {
    let data = tcp.peek_at_least(need) catch {
      @io.ReaderClosed => return None
      e => raise classify(Head, e)
    }
    match @model.scan_head(data, max~) {
      Some(n) => return Some(n)
      None => need = data.length() + 1
    }
  }
}

///|
priv struct ServerStream {
  conn : @ahttp.ServerConnection
  buf : FixedArray[Byte]
  mut done : Bool
}

///|
impl @model.BodyStream for ServerStream with read_some(self) {
  if self.done {
    return None
  }
  let n = self.conn.read_into(self.buf, max_len=65536) catch {
    e => {
      self.done = true
      raise classify(Body, e)
    }
  }
  if n == 0 {
    self.done = true
    None
  } else {
    Some(Bytes::from_fixedarray(self.buf, len=n))
  }
}

///|
impl @model.BodyStream for ServerStream with close(self) {
  self.done = true
}

///|
async fn write_raw_response(
  tcp : @socket.Tcp,
  resp : @model.ServerResponse,
) -> Unit {
  // Written on the raw socket so duplicate response headers survive (the
  // runtime's send_response takes a Map and merges or drops duplicates).
  let body = match resp.body {
    Bytes(b) => b
    _ => b""
  }
  let sb = StringBuilder()
  sb.write_string("HTTP/1.1 \{resp.status} X\r\n")
  for pair in resp.headers.iter() {
    sb.write_string(pair.0 + ": " + pair.1 + "\r\n")
  }
  sb.write_string("Content-Length: \{body.length()}\r\n")
  if resp.close_connection {
    sb.write_string("Connection: close\r\n")
  }
  sb.write_string("\r\n")
  tcp.write(@utf8.encode(sb.to_string()))
  tcp.write(body)
}

///|
async fn serve_conn(
  tcp : @socket.Tcp,
  handler : @model.Handler,
  limits : ServerLimits,
) -> Unit {
  let conn = @ahttp.ServerConnection::new(tcp)
  defer conn.close()
  for ;; {
    let got = @async.with_timeout_opt(limits.header_timeout_ms, () => {
      let dups = if limits.prescan_head {
        match prescan(tcp, limits.max_header_bytes) {
          None => return None
          Some(n) => Some(@model.parse_head_headers(tcp.peek_exactly(n)))
        }
      } else {
        None
      }
      Some((conn.read_request(), dups))
    }) catch {
      @model.TransportError::TransportError(kind=TooLarge(_), ..) => {
        write_raw_response(tcp, {
          status: 431,
          headers: @model.Headers::empty(),
          body: Empty,
          close_connection: true,
        }) catch { _ => () }
        return
      }
      _ => return
    }
    guard got is Some(Some((req, dups))) else { return }
    let headers = match dups {
      Some(h) => h
      None => {
        let pairs = []
        for k, v in req.headers {
          pairs.push((k.to_string(), v))
        }
        @model.Headers::of(pairs)
      }
    }
    let stream = ServerStream::{ conn, buf: FixedArray::make(65536, 0), done: false }
    let mreq : @model.Request = {
      meth: req.meth.to_string(),
      url: req.path,
      headers,
      body: Stream(stream, length=None),
    }
    let outcome = handler(mreq)
    conn.skip_request_body() catch { _ => return }
    match outcome {
      Respond(resp) => {
        write_raw_response(tcp, resp) catch { _ => return }
        if resp.close_connection {
          return
        }
      }
    }
  }
}

///|
/// Runs until cancelled. No runtime type in the signature.
pub async fn serve(
  handler : @model.Handler,
  addr~ : String,
  on_listen? : (String) -> Unit,
  limits? : ServerLimits = ServerLimits::default(),
) -> Unit raise ServerConfigError {
  guard limits.max_connections > 0 else {
    raise InvalidMaxConnections(value=limits.max_connections)
  }
  let server = (try {
    @socket.TcpServer(@socket.Addr::parse(addr), reuse_addr=true)
  } catch {
    e => raise Bind(detail=e.to_string())
  }) 
  defer server.close()
  if on_listen is Some(f) {
    f(server.addr.to_string())
  }
  server.run_forever(allow_failure=true, max_connections=limits.max_connections, (tcp, _) => {
    serve_conn(tcp, handler, limits)
  }) catch {
    e => raise Bind(detail=e.to_string())
  }
}
