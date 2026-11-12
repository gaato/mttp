// The interop server: gaato/mttp_async's server with a handful of endpoints
// that report what arrived, so that a third-party client or proxy in front
// of it can be checked from the outside. interop/run.mbtx starts it and
// drives it directly (curl, Go, Python, Node, Bun, Deno, raw sockets) and
// through nginx, Caddy and Apache.
//
//   GET  /conn                 the peer address, which names the connection
//   ANY  /echo                 method, target, framing, Expect and the
//                              body's length and digest
//   GET  /headers              the request's header fields, one per line
//   GET  /stream?pieces=&size=&delay_ms=
//                              the binary pattern, streamed in pieces
//                              (chunked on HTTP/1.1)
//   GET  /bytes?n=             the binary pattern with a Content-Length
//   GET  /delay?ms=            answers after `ms` milliseconds
//   GET  /status/NNN           that status
//   GET  /log[?reset=1]        what reached the server since the last reset:
//                              one line per request and per refused
//                              connection (`error ...`)
//
//   mttp_server <address>      serves on <address>
//   mttp_server www <dir>      writes the static files the third-party
//                              servers serve (interop/pattern) into <dir>

///|
/// What reached the server, for /log.
let log : Array[String] = []

///|
/// The largest request body the server accepts: above the 16 MiB the
/// clients upload.
let max_body : Int32 = 64 << 20

///|
/// The framing a request arrived with, as its header fields say.
fn framing(headers : @mttp.Headers) -> String {
  let te = headers.get_all("transfer-encoding")
  let cl = headers.get_all("content-length")
  if !te.is_empty() {
    "chunked"
  } else if cl is [length] {
    "length:\{length}"
  } else {
    "none"
  }
}

///|
/// The text of a field, or `-`.
fn field(headers : @mttp.Headers, name : String) -> String {
  headers.get_all(name).join(", ") |> or_dash
}

///|
fn or_dash(s : String) -> String {
  if s.is_empty() {
    "-"
  } else {
    s
  }
}

///|
fn text(status : Int32, body : String) -> @mttp.Response {
  @mttp.Response::new(
    status,
    headers=@mttp.Headers::of([("Content-Type", "text/plain")]),
    body=Bytes(@mttp.encode_utf8(body)),
  )
}

///|
/// A query parameter as a number, or `default`.
fn number(
  params : Array[(String, String)],
  name : String,
  default : Int32,
) -> Int32 {
  for pair in params {
    if pair.0 == name {
      return @string.parse_int(pair.1) catch { _ => default }
    }
  }
  default
}

///|
/// The binary pattern in `pieces` pieces of `size` bytes, with `delay_ms`
/// between them.
priv struct Pieces {
  pieces : Int32
  size : Int32
  delay_ms : Int32
  mut sent : Int32
}

///|
impl @mttp.BodyStream for Pieces with fn read_some(self) {
  if self.sent >= self.pieces {
    return None
  }
  if self.sent > 0 && self.delay_ms > 0 {
    @async.sleep(self.delay_ms)
  }
  let start = self.sent * self.size
  self.sent += 1
  Some(Bytes::makei(self.size, i => @pattern.byte_at(start + i)))
}

///|
impl @mttp.BodyStream for Pieces with fn close(self) {
  self.sent = self.pieces
}

///|
async fn handle(request : @mttp.Request) -> @mttp.Response noraise {
  let url = @mttp.Url::parse(request.url) catch {
    _ => return text(400, "unparsable target\n")
  }
  let target = match url.query {
    Some(q) => "\{url.path}?\{q}"
    None => url.path
  }
  let params = url.query_params()
  let peer = request.attributes.get(@mttp.remote_addr).unwrap_or("-")
  if url.path == "/log" {
    let lines = log.join("\n")
    if number(params, "reset", 0) == 1 {
      log.clear()
    }
    return text(200, if lines.is_empty() { "" } else { lines + "\n" })
  }
  log.push("\{request.meth} \{target} \{framing(request.headers)}")
  match url.path {
    "/conn" => text(200, "\{peer}\n")
    "/echo" => {
      let digest = @pattern.Digest::new()
      let body = request.body.read_all(max=max_body) catch {
        error => return text(400, "body: \{error}\n")
      }
      digest.update(body)
      let lines = [
        "method \{request.meth}",
        "target \{target}",
        "framing \{framing(request.headers)}",
        "expect \{field(request.headers, "expect")}",
        "body \{digest.summary()}",
        "peer \{peer}",
      ]
      text(200, lines.join("\n") + "\n")
    }
    "/headers" => {
      let lines = request.headers.iter().map(h => "\{h.0}: \{h.1}").to_array()
      text(200, lines.join("\n") + "\n")
    }
    "/stream" => {
      let pieces = Pieces::{
        pieces: number(params, "pieces", 8),
        size: number(params, "size", 1024),
        delay_ms: number(params, "delay_ms", 0),
        sent: 0,
      }
      @mttp.Response::new(200, body=Stream(@mttp.StreamBody::new(pieces)))
    }
    "/bytes" => {
      let n = number(params, "n", 0)
      @mttp.Response::new(200, body=Bytes(@pattern.binary(n)))
    }
    "/delay" => {
      @async.sleep(number(params, "ms", 0))
      text(200, "late\n")
    }
    path if path.has_prefix("/status/") => {
      let code = @string.parse_int(path["/status/".length():]) catch {
        _ => 400
      }
      if code == 204 || code == 304 {
        @mttp.Response::new(code)
      } else {
        text(code, "status \{code}\n")
      }
    }
    _ => text(404, "no such endpoint\n")
  }
}

///|
fn main {
  let args = @env.args()
  if args is [_, "www", dir] {
    @mttp_async.run(async fn() {
      @fs.mkdir(dir, recursive=true, allow_exist=true)
      for file in @pattern.files() {
        @fs.write_binary("\{dir}/\{file.0}", file.1)
      }
      @fs.write_text("\{dir}/digests.txt", @pattern.digests())
    })
    return
  }
  guard args.length() == 2 else {
    println("usage: mttp_server <address> | mttp_server www <dir>")
    @env.exit(2)
  }
  @mttp_async.run(async fn() {
    @server.serve(
      handle,
      addr=args[1],
      limits={
        ..@h1server.ServerLimits::default(),
        max_body_bytes: max_body,
        drain_max_bytes: max_body,
      },
      on_listen=addr => println("listening on \{addr}"),
      on_error=error => log.push("error \{error}"),
    )
  })
}
