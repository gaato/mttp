// The interop client: gaato/mttp's Client and backend against a
// third-party server (nginx, Caddy, Apache httpd). interop/run.mbtx runs it
// once per server, scheme and runtime (native; js under Node, Bun and
// Deno) with the cases interop/cases.tsv selects, and compares each line
// it prints with the expectation there:
//
//   mttp_client <base> <alt> <ca.pem|-> <case,case,...>
//
// prints `CASE <id> ok <detail>` or `CASE <id> fail <detail>` per case.
// <base> is the server's origin, <alt> the same server on another origin
// (127.0.0.2), and every server serves the same layout:
//
//   /small.txt /text.txt /large.bin   static files (interop/pattern)
//   /slow.bin                         16 KiB sent at about 4 KiB/s
//   /up/...                           the mttp interop server, proxied
//   /r/301 /r/302 /r/307 /r/308       redirects to /up/echo
//   /same /xo                         302 to /up/headers on this origin,
//                                     and on <alt>
//   /down                             302 from https to http (https only)
//   /s/204                            204
//   /limited/echo                     /up/echo behind a 1 KiB body limit
//                                     (a static file on Apache)
//   /drop                             closes the connection unanswered
//
// and sets an `X-Conn` header naming the connection on every response.

///|
suberror Check {
  Check(String)
}

///|
fn check(ok : Bool, what : String) -> Unit raise Check {
  if !ok {
    raise Check(what)
  }
}

///|
priv struct Ctx {
  base : String
  alt : String
  trust : @mttp.Trust
}

///|
fn Ctx::url(self : Ctx, path : String) -> String {
  self.base + path
}

///|
/// The deadline the raw sends get: generous, since the slow cases have
/// their own.
let raw_timeout : Int32 = 30000

///|
fn Ctx::backend(self : Ctx) -> @backend.AsyncBackend {
  @backend.AsyncBackend::new(trust=self.trust)
}

///|
/// A Client with the defaults `@mttp.client()` uses, retries off
/// unless asked for, so a case sees each failure as it happened.
fn Ctx::client(
  self : Ctx,
  retry~ : @client.RetryPolicy = @client.RetryPolicy::none(),
  timeout_ms~ : Int32 = raw_timeout,
  observer? : (@client.Attempt) -> Unit,
) -> @client.Client {
  @client.Client::new(
    self.backend(),
    @mttp.clock(),
    timer=@mttp.timer(),
    timeout_ms~,
    retry~,
    observer?,
    // The spread of retry waits does not matter here; fixing it keeps runs
    // comparable.
    random=() => 0.5,
  )
}

///|
/// One raw exchange on `backend`, with the body read to its end.
async fn exchange(
  backend : @backend.AsyncBackend,
  request : @mttp_core.Request,
) -> (@mttp_core.Response, Bytes) {
  let response = backend.send(request, {
    timeout_ms: Some(raw_timeout),
    body: Exchange(max_bytes=64 << 20),
  })
  let body = response.body.read_all(max=64 << 20)
  (response, body)
}

///|
fn conn_of(response : @mttp_core.Response) -> String raise Check {
  match response.headers.get("x-conn") {
    Some(id) => id
    None => raise Check("no X-Conn header")
  }
}

///|
fn text_of(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes)
}

///|
/// The value of `key` in the `key value` lines /up/echo answers with.
fn echoed(body : Bytes, key : String) -> String raise Check {
  for line in text_of(body).split("\n") {
    if line.has_prefix(key + " ") {
      return line[key.length() + 1:].to_owned()
    }
  }
  raise Check("the echo has no \{key}: \{text_of(body)}")
}

///|
fn now() -> Int64 {
  @mttp.clock().now_unix_ms()
}

///|
async fn pause(ms : Int32) -> Unit {
  @mttp.clock().sleep(ms)
}

///|
/// Whether mttp pools the connections itself, so that a case can check
/// that a request reused one. On js the host's fetch pools them.
#cfg(target="js")
let pools_connections : Bool = false

///|
#cfg(not(target="js"))
let pools_connections : Bool = true

///|
/// How long the servers keep an idle connection (their configs set 2 s),
/// plus a margin.
let past_idle_ms : Int32 = 3500

///|
/// A stream of the binary pattern in pieces, with no declared length, so
/// the request goes out chunked.
priv struct Upload {
  total : Int32
  piece : Int32
  mut sent : Int32
}

///|
impl @mttp_core.BodyStream for Upload with fn read_some(self) {
  if self.sent >= self.total {
    return None
  }
  let n = (self.total - self.sent).min(self.piece)
  let start = self.sent
  self.sent += n
  Some(Bytes::makei(n, i => @pattern.byte_at(start + i)))
}

///|
impl @mttp_core.BodyStream for Upload with fn close(self) {
  self.sent = self.total
}

// The cases. Each returns a detail on success and raises on failure.

///|
async fn case_get(ctx : Ctx) -> String {
  let client = ctx.client()
  defer client.close()
  let reply = @client.get(ctx.url("/small.txt")).send(client)
  check(reply.status == 200, "status \{reply.status}")
  check(
    reply.body is Ok("hello interop\n"),
    "body \{@debug.to_string(reply.body)}",
  )
  "200"
}

///|
async fn case_keepalive(ctx : Ctx) -> String {
  let backend = ctx.backend()
  defer backend.close()
  let ids = []
  for _ in 0..<3 {
    let (response, body) = exchange(
      backend,
      @mttp_core.Request::get(ctx.url("/small.txt")),
    )
    check(body == b"hello interop\n", "body")
    ids.push(conn_of(response))
  }
  check(
    ids[0] == ids[1] && ids[1] == ids[2],
    "connections \{@debug.to_string(ids)}",
  )
  check(
    backend.idle_connections() == 1,
    "\{backend.idle_connections()} idle connections",
  )
  "one connection for 3 requests"
}

///|
/// A request after the server closed the kept-alive connection must go out
/// on a fresh one: the pool notices the close, or a GET is resent once.
async fn case_idle_close_get(ctx : Ctx) -> String {
  let backend = ctx.backend()
  defer backend.close()
  let (first, _) = exchange(
    backend,
    @mttp_core.Request::get(ctx.url("/small.txt")),
  )
  pause(past_idle_ms)
  let (second, body) = exchange(
    backend,
    @mttp_core.Request::get(ctx.url("/small.txt")),
  )
  check(body == b"hello interop\n", "body")
  check(conn_of(first) != conn_of(second), "the closed connection answered")
  match second.attributes.get(@h1client.stale_resend) {
    Some(true) => "resent after a stale connection"
    _ => "new connection"
  }
}

///|
/// The same with a POST, which may not be resent once sent: it must not be
/// written to the closed connection, and it must reach the server once.
async fn case_idle_close_post(ctx : Ctx) -> String {
  let attempts = []
  let client = ctx.client(retry=@client.RetryPolicy::conservative(), observer=a => {
    attempts.push(a)
  })
  defer client.close()
  let post = () => {
    @client.post(ctx.url("/up/echo")).body_bytes(@pattern.binary(1000))
  }
  ignore(@client.get(ctx.url("/up/log?reset=1")).send(client))
  let first = post().send(client)
  check(first.status == 200, "first status \{first.status}")
  pause(past_idle_ms)
  attempts.clear()
  let second = post().send(client)
  check(second.status == 200, "second status \{second.status}")
  check(attempts.length() == 1, "\{attempts.length()} attempts")
  let log = @client.get(ctx.url("/up/log")).send(client)
  guard log.body is Ok(lines) else {
    raise Check("log \{@debug.to_string(log.body)}")
  }
  let posts = lines.split("\n").filter(l => l.has_prefix("POST /echo")).count()
  check(posts == 2, "the server saw \{posts} POSTs, not 2")
  "sent once on a fresh connection"
}

///|
/// A chunked response the server (or proxy) framed itself.
async fn case_chunked_response(ctx : Ctx) -> String {
  let backend = ctx.backend()
  defer backend.close()
  let (response, body) = exchange(
    backend,
    @mttp_core.Request::get(
      ctx.url("/up/stream?pieces=8&size=4096&delay_ms=20"),
    ),
  )
  check(response.status == 200, "status \{response.status}")
  check(
    @pattern.digest(body) == @pattern.digest(@pattern.binary(8 * 4096)),
    "body \{@pattern.digest(body)}",
  )
  match response.headers.get("transfer-encoding") {
    Some(te) => "transfer-encoding \{te}"
    // On js the host decodes the framing and may hide the field.
    None => "length \{body.length()}"
  }
}

///|
/// The server encodes text.txt with `coding`; mttp's decoder undoes it.
async fn case_coding(ctx : Ctx, coding : String) -> String {
  let backend = ctx.backend()
  defer backend.close()
  let response = backend.send(
    @mttp_core.Request::get(ctx.url("/text.txt")).header(
      "Accept-Encoding", coding,
    ),
    { timeout_ms: Some(raw_timeout), body: Stream(idle_ms=Some(raw_timeout)), },
  )
  defer response.close()
  check(response.status == 200, "status \{response.status}")
  let sent = response.headers.get("content-encoding").unwrap_or("identity")
  check(sent == coding, "content-encoding \{sent}")
  let (_, decoder) = @codings.decode_head(response.head())
  guard response.body is Stream(stream) else { raise Check("no body") }
  let wire = stream.take()
  defer wire.close()
  let wire_bytes = Ref(0)
  let out = Buffer()
  while @codings.read_decoded(
          () => {
            let piece = wire.read_some()
            if piece is Some(p) {
              wire_bytes.val += p.length()
            }
            piece
          },
          decoder,
        )
        is Some(piece) {
    out.write_bytes(piece)
  }
  let decoded = out.to_bytes()
  check(
    decoded == @pattern.text(256 << 10),
    "decoded \{decoded.length()} bytes",
  )
  "\{wire_bytes.val} \{coding} bytes decoded to \{decoded.length()}"
}

///|
/// The Client's default negotiation: whatever the server picks decodes.
async fn case_decompress(ctx : Ctx) -> String {
  let client = ctx.client()
  defer client.close()
  let reply = @client.get(ctx.url("/text.txt"))
    .response(@client.as_bytes())
    .send(client)
  guard reply.body is Ok(body) else {
    raise Check("body \{@debug.to_string(reply.body)}")
  }
  check(body == @pattern.text(256 << 10), "body \{body.length()} bytes")
  "\{body.length()} bytes"
}

///|
/// Checks that the next request on the same backend reuses the connection
/// of `previous` and gets the right body: the bodiless answer left nothing
/// behind on the wire.
async fn next_on_same(
  backend : @backend.AsyncBackend,
  ctx : Ctx,
  previous : @mttp_core.Response,
  same_conn : Bool,
) -> Unit {
  let (response, body) = exchange(
    backend,
    @mttp_core.Request::get(ctx.url("/small.txt")),
  )
  check(body == b"hello interop\n", "next body \{text_of(body)}")
  if same_conn {
    check(
      conn_of(response) == conn_of(previous),
      "the next request used another connection",
    )
  }
}

///|
async fn case_head(ctx : Ctx, same_conn : Bool) -> String {
  let backend = ctx.backend()
  defer backend.close()
  let (response, body) = exchange(
    backend,
    @mttp_core.Request::new(Head, ctx.url("/large.bin")),
  )
  check(response.status == 200, "status \{response.status}")
  check(body.is_empty(), "\{body.length()} body bytes")
  let length = response.headers.get("content-length")
  check(
    length == Some(@pattern.large_bytes.to_string()),
    "content-length \{@debug.to_string(length)}",
  )
  next_on_same(backend, ctx, response, same_conn)
  "content-length \{length.unwrap()}, no body"
}

///|
async fn case_no_content(ctx : Ctx, same_conn : Bool) -> String {
  let backend = ctx.backend()
  defer backend.close()
  let (response, body) = exchange(
    backend,
    @mttp_core.Request::get(ctx.url("/s/204")),
  )
  check(response.status == 204, "status \{response.status}")
  check(body.is_empty(), "\{body.length()} body bytes")
  next_on_same(backend, ctx, response, same_conn)
  "204"
}

///|
async fn case_not_modified(ctx : Ctx, same_conn : Bool) -> String {
  let backend = ctx.backend()
  defer backend.close()
  let (first, _) = exchange(
    backend,
    @mttp_core.Request::get(ctx.url("/small.txt")),
  )
  guard first.headers.get("etag") is Some(etag) else { raise Check("no ETag") }
  let (response, body) = exchange(
    backend,
    @mttp_core.Request::get(ctx.url("/small.txt")).header("If-None-Match", etag),
  )
  check(response.status == 304, "status \{response.status}")
  check(body.is_empty(), "\{body.length()} body bytes")
  next_on_same(backend, ctx, response, same_conn)
  "304 for \{etag}"
}

///|
/// A POST redirected with `status`: 301 and 302 turn it into a GET without
/// the body, 307 and 308 resend it.
async fn case_redirect(ctx : Ctx, status : Int32) -> String {
  let client = ctx.client()
  defer client.close()
  let payload = @pattern.binary(5000)
  let reply = @client.post(ctx.url("/r/\{status}"))
    .body_bytes(payload)
    .response(@client.as_bytes())
    .send(client)
  guard reply.body is Ok(body) else {
    raise Check("reply \{@debug.to_string(reply.body)}")
  }
  let meth = echoed(body, "method")
  let received = echoed(body, "body")
  let hops = reply.attributes.get(@client.redirect_history).map(h => h.length())
  check(hops == Some(1), "hops \{@debug.to_string(hops)}")
  if status == 301 || status == 302 {
    check(meth == "GET", "method \{meth}")
    check(received == "0:811c9dc5", "body \{received}")
  } else {
    check(meth == "POST", "method \{meth}")
    check(received == @pattern.digest(payload), "body \{received}")
  }
  "\{meth} with body \{received}"
}

///|
/// Credentials survive a same-origin redirect and are dropped on a
/// cross-origin one.
async fn case_redirect_credentials(ctx : Ctx, cross : Bool) -> String {
  let client = ctx.client()
  defer client.close()
  let reply = @client.get(ctx.url(if cross { "/xo" } else { "/same" }))
    .header("Authorization", "Bearer interop")
    .header("Cookie", "session=interop")
    .header("X-Interop", "kept")
    .send(client)
  guard reply.body is Ok(headers) else {
    raise Check("reply \{@debug.to_string(reply.body)}")
  }
  let lines = headers.split("\n").map(l => l.to_lower()).to_array()
  let has = (name : String) => lines.any(l => l.has_prefix(name + ":"))
  let final_url = reply.attributes.get(@client.final_url).unwrap_or("?")
  check(has("x-interop"), "x-interop was dropped")
  if cross {
    check(final_url.has_prefix(ctx.alt), "ended at \{final_url}")
    check(!has("authorization"), "authorization crossed origins")
    check(!has("cookie"), "cookie crossed origins")
    "dropped at \{final_url}"
  } else {
    check(has("authorization"), "authorization was dropped")
    check(has("cookie"), "cookie was dropped")
    "kept"
  }
}

///|
async fn case_redirect_downgrade(ctx : Ctx) -> String {
  let client = ctx.client()
  defer client.close()
  let reply = @client.get(ctx.url("/down")).send(client) catch {
    @mttp_core.TransportError(kind=RedirectRefused, ..) as error =>
      return "refused: \{error}"
    error => raise error
  }
  raise Check("followed to status \{reply.status}")
}

///|
async fn upload(
  ctx : Ctx,
  path : String,
  request : @mttp_core.Request,
  expected : String,
) -> String {
  let client = ctx.client()
  defer client.close()
  let reply = @client.request(request).response(@client.as_bytes()).send(client)
  guard reply.body is Ok(body) else {
    raise Check("status \{reply.status} at \{path}")
  }
  let received = echoed(body, "body")
  check(received == expected, "the server got \{received}")
  "\{echoed(body, "framing")}, \{received}"
}

///|
async fn case_upload(ctx : Ctx, size : Int32) -> String {
  let payload = @pattern.binary(size)
  upload(
    ctx,
    "/up/echo",
    @mttp_core.Request::post(ctx.url("/up/echo")).body_bytes(payload),
    @pattern.digest(payload),
  )
}

///|
async fn case_chunked_upload(ctx : Ctx) -> String {
  let size = 4 << 20
  upload(
    ctx,
    "/up/echo",
    @mttp_core.Request::post(ctx.url("/up/echo")).body_stream(Upload::{
      total: size,
      piece: 65536,
      sent: 0,
    }),
    @pattern.digest(@pattern.binary(size)),
  )
}

///|
async fn case_expect_continue(ctx : Ctx) -> String {
  let payload = @pattern.binary(1 << 20)
  upload(
    ctx,
    "/up/echo",
    @mttp_core.Request::post(ctx.url("/up/echo"))
    .body_bytes(payload)
    .header("Expect", "100-continue"),
    @pattern.digest(payload),
  )
}

///|
/// The server refuses a body over its limit as soon as it sees the head;
/// the client stops uploading and reports the 413, and the next request
/// works.
async fn case_expect_refused(ctx : Ctx) -> String {
  let client = ctx.client()
  defer client.close()
  let started = now()
  let reply = @client.post(ctx.url("/limited/echo"))
    .body_bytes(@pattern.binary(8 << 20))
    .header("Expect", "100-continue")
    .send(client)
  let took = now() - started
  check(reply.status == 413, "status \{reply.status}")
  let next = @client.get(ctx.url("/small.txt")).send(client)
  check(
    next.body is Ok("hello interop\n"),
    "next \{@debug.to_string(next.body)}",
  )
  "413 after \{took} ms"
}

///|
async fn case_large_download(ctx : Ctx) -> String {
  let client = ctx.client()
  defer client.close()
  let reply = @client.get(ctx.url("/large.bin"))
    .response(@client.as_bytes())
    .send(client)
  guard reply.body is Ok(body) else {
    raise Check("reply \{@debug.to_string(reply.body)}")
  }
  let got = @pattern.digest(body)
  check(
    got == @pattern.digest(@pattern.binary(@pattern.large_bytes)),
    "body \{got}",
  )
  got
}

///|
/// slow.bin arrives over about four seconds; a 10 s deadline lets it.
async fn case_slow_body(ctx : Ctx) -> String {
  let client = ctx.client(timeout_ms=10000)
  defer client.close()
  let started = now()
  let reply = @client.get(ctx.url("/slow.bin"))
    .response(@client.as_bytes())
    .send(client)
  let took = now() - started
  guard reply.body is Ok(body) else {
    raise Check("reply \{@debug.to_string(reply.body)}")
  }
  check(
    @pattern.digest(body) == @pattern.digest(@pattern.binary(16 << 10)),
    "body \{@pattern.digest(body)}",
  )
  check(took >= 1500L, "only \{took} ms: the server did not trickle")
  "\{body.length()} bytes in \{took} ms"
}

///|
/// The same body with a 1 s deadline: the attempt fails with Timeout in
/// time, though bytes keep arriving.
async fn case_slow_deadline(ctx : Ctx) -> String {
  let client = ctx.client(timeout_ms=1000)
  defer client.close()
  let started = now()
  let reply = @client.get(ctx.url("/slow.bin")).send(client) catch {
    @mttp_core.TransportError(kind=Timeout(..), phase~, ..) => {
      let took = now() - started
      check(took < 2500L, "timed out only after \{took} ms")
      return "Timeout in \{@debug.to_string(phase)} after \{took} ms"
    }
    error => raise error
  }
  raise Check("status \{reply.status} instead of a timeout")
}

///|
/// A head that comes after 3 s, with a 1 s deadline.
async fn case_head_deadline(ctx : Ctx) -> String {
  let client = ctx.client(timeout_ms=1000)
  defer client.close()
  let started = now()
  let reply = @client.get(ctx.url("/up/delay?ms=3000")).send(client) catch {
    @mttp_core.TransportError(kind=Timeout(..), phase~, ..) => {
      let took = now() - started
      check(took < 2500L, "timed out only after \{took} ms")
      return "Timeout in \{@debug.to_string(phase)} after \{took} ms"
    }
    error => raise error
  }
  raise Check("status \{reply.status} instead of a timeout")
}

///|
/// The server closes the connection without answering. A GET is
/// idempotent and is retried (twice, by the default policy); a POST was
/// sent, so it is not.
async fn case_drop(ctx : Ctx, post : Bool) -> String {
  let attempts = []
  let client = ctx.client(retry=@client.RetryPolicy::conservative(), observer=a => {
    attempts.push(a)
  })
  defer client.close()
  let request = if post {
    @mttp_core.Request::post(ctx.url("/drop")).body_bytes(b"payload")
  } else {
    @mttp_core.Request::get(ctx.url("/drop"))
  }
  let reply = @client.request(request).send(client) catch {
    @mttp_core.TransportError(..) as error => {
      let expected = if post { 1 } else { 3 }
      check(!error.is_unsent(), "classified as unsent: \{error}")
      check(
        attempts.length() == expected,
        "\{attempts.length()} attempts, not \{expected}: \{error}",
      )
      return "\{attempts.length()} attempts, sent: \{error}"
    }
    error => raise error
  }
  raise Check("status \{reply.status} instead of a failure")
}

///|
/// Runs one case by its id.
async fn run_case(ctx : Ctx, id : String) -> String {
  match id {
    "get" => case_get(ctx)
    "keepalive" => case_keepalive(ctx)
    "idle-close-get" => case_idle_close_get(ctx)
    "idle-close-post" => case_idle_close_post(ctx)
    "chunked-response" => case_chunked_response(ctx)
    "gzip" => case_coding(ctx, "gzip")
    "br" => case_coding(ctx, "br")
    "zstd" => case_coding(ctx, "zstd")
    "decompress" => case_decompress(ctx)
    "head" => case_head(ctx, pools_connections)
    "no-content" => case_no_content(ctx, pools_connections)
    "not-modified" => case_not_modified(ctx, pools_connections)
    "redirect-301" => case_redirect(ctx, 301)
    "redirect-302" => case_redirect(ctx, 302)
    "redirect-307" => case_redirect(ctx, 307)
    "redirect-308" => case_redirect(ctx, 308)
    "redirect-same-origin" => case_redirect_credentials(ctx, false)
    "redirect-cross-origin" => case_redirect_credentials(ctx, true)
    "redirect-downgrade" => case_redirect_downgrade(ctx)
    "expect-continue" => case_expect_continue(ctx)
    "expect-refused" => case_expect_refused(ctx)
    "large-download" => case_large_download(ctx)
    "large-upload" => case_upload(ctx, 8 << 20)
    "chunked-upload" => case_chunked_upload(ctx)
    "slow-body" => case_slow_body(ctx)
    "slow-deadline" => case_slow_deadline(ctx)
    "head-deadline" => case_head_deadline(ctx)
    "drop-get" => case_drop(ctx, false)
    "drop-post" => case_drop(ctx, true)
    _ => raise Check("unknown case")
  }
}

///|
fn main {
  let args = @env.args()
  // On js the host may put its own arguments first.
  guard args.length() >= 4 else {
    println("usage: mttp_client <base> <alt> <ca.pem|-> <case,...>")
    @env.exit(2)
  }
  let n = args.length()
  let ctx = Ctx::{
    base: args[n - 4],
    alt: args[n - 3],
    trust: if args[n - 2] == "-" {
      System
    } else {
      PemFile(args[n - 2])
    },
  }
  let ids = args[n - 1].split(",").map(s => s.to_owned()).to_array()
  @mttp.run(async fn() {
    for id in ids {
      let line = try run_case(ctx, id) catch {
        Check(what) => "fail \{what}"
        error => "fail \{error}"
      } noraise {
        detail => "ok \{detail}"
      }
      println("CASE \{id} \{line}")
    }
  })
}
