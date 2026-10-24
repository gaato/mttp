// moonbitlang/async 0.22.5 variant: same public signatures as the core-main
// variant. Implementation differences are listed inline as `0.22.5:`.

///|
fn tx(kind : @model.Kind, phase : @model.Phase, detail : String) -> @model.TransportError {
  @model.TransportError::TransportError(kind~, phase~, detail~)
}

///|
fn classify(phase : @model.Phase, e : Error) -> @model.TransportError {
  match e {
    @model.TransportError::TransportError(..) as t => t
    // 0.22.5: URIParseError (core-main renamed it UriParseError)
    @ahttp.URIParseError::InvalidFormat => tx(Invalid, phase, "invalid URL")
    @ahttp.URIParseError::UnsupportedProtocol(p) =>
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
  mut done : Bool
}

///|
impl @model.BodyStream for ClientStream with read_some(self) {
  if self.done {
    return None
  }
  // 0.22.5: read_some(max_len~); core-main: read_into(buf, max_len~)
  let chunk = self.client.read_some(max_len=65536) catch {
    e => {
      self.done = true
      self.client.close()
      raise classify(Body, e)
    }
  }
  if chunk is None {
    self.done = true
    self.client.close()
  }
  chunk
}

///|
impl @model.BodyStream for ClientStream with close(self) {
  if !self.done {
    self.done = true
    self.client.close()
  }
}

///|
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
    body: Stream(ClientStream::{ client, done: false }, length=None),
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
async fn write_raw_response(
  tcp : @socket.Tcp,
  resp : @model.ServerResponse,
) -> Unit {
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
  // 0.22.5: write(&@io.Data); core-main: write(BytesView)
  tcp.write(@utf8.encode(sb.to_string()))
  tcp.write(body)
}

///|
fn too_large() -> @model.ServerResponse {
  { status: 431, headers: @model.Headers::empty(), body: Empty, close_connection: true }
}

///|
/// 0.22.5 has no peek on Tcp, so a bounded head needs our own codec: the
/// head and a Content-Length body are framed here, never by ServerConnection.
async fn serve_conn_own_codec(
  tcp : @socket.Tcp,
  handler : @model.Handler,
  limits : ServerLimits,
) -> Unit {
  defer tcp.close()
  let mut acc : Bytes = b""
  for ;; {
    let head = @async.with_timeout_opt(limits.header_timeout_ms, () => {
      for ;; {
        match @model.scan_head(acc, max=limits.max_header_bytes) {
          Some(n) => return Some(n)
          None => ()
        }
        let room = limits.max_header_bytes + 4 - acc.length()
        match tcp.read_some(max_len=if room < 1 { 1 } else { room }) {
          None => return None
          Some(chunk) => acc = acc + chunk
        }
      }
    }) catch {
      @model.TransportError::TransportError(kind=TooLarge(_), ..) => {
        write_raw_response(tcp, too_large()) catch { _ => () }
        return
      }
      _ => return
    }
    guard head is Some(Some(n)) else { return }
    let head_bytes = acc[:n]
    let first = @utf8.decode_lossy(head_bytes)
    let line_end = first.find("\r\n").unwrap_or(0)
    let parts = first[:line_end].split(" ").collect()
    guard parts.length() == 3 else { return }
    let headers = @model.parse_head_headers(head_bytes)
    if headers.get("transfer-encoding") is Some(_) {
      // A bounded chunked decoder would live in mttp (sans-IO); omitted here.
      write_raw_response(tcp, {
        status: 501, headers: @model.Headers::empty(), body: Empty, close_connection: true,
      }) catch { _ => () }
      return
    }
    let length = match headers.get("content-length") {
      None => 0
      Some(v) => @string.parse_int(v) catch { _ => -1 }
    }
    guard length >= 0 && length <= limits.max_body_bytes else {
      write_raw_response(tcp, {
        status: 413, headers: @model.Headers::empty(), body: Empty, close_connection: true,
      }) catch { _ => () }
      return
    }
    acc = acc[n:].to_bytes()
    while acc.length() < length {
      match tcp.read_some(max_len=length - acc.length()) {
        None => return
        Some(chunk) => acc = acc + chunk
      }
    }
    let body = acc[:length].to_bytes()
    acc = acc[length:].to_bytes()
    let outcome = handler({
      meth: parts[0].to_owned(),
      url: parts[1].to_owned(),
      headers,
      body: Bytes(body),
    })
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
priv struct ServerStream {
  conn : @ahttp.ServerConnection
  mut done : Bool
}

///|
impl @model.BodyStream for ServerStream with read_some(self) {
  if self.done {
    return None
  }
  let chunk = self.conn.read_some(max_len=65536) catch {
    e => {
      self.done = true
      raise classify(Body, e)
    }
  }
  if chunk is None {
    self.done = true
  }
  chunk
}

///|
impl @model.BodyStream for ServerStream with close(self) {
  self.done = true
}

///|
async fn serve_conn_stock(
  tcp : @socket.Tcp,
  handler : @model.Handler,
  limits : ServerLimits,
) -> Unit {
  let conn = @ahttp.ServerConnection::new(tcp)
  defer conn.close()
  for ;; {
    let got = @async.with_timeout_opt(limits.header_timeout_ms, () => {
      conn.read_request()
    }) catch {
      _ => return
    }
    guard got is Some(req) else { return }
    let pairs = []
    for k, v in req.headers {
      pairs.push((k.to_string(), v))
    }
    let outcome = handler({
      meth: req.meth.to_string(),
      url: req.path,
      headers: @model.Headers::of(pairs),
      body: Stream(ServerStream::{ conn, done: false }, length=None),
    })
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
    if limits.prescan_head {
      serve_conn_own_codec(tcp, handler, limits)
    } else {
      serve_conn_stock(tcp, handler, limits)
    }
  }) catch {
    e => raise Bind(detail=e.to_string())
  }
}
