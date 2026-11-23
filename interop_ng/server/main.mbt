// The server h2spec and the other HTTP/2 and HTTP/3 peers are pointed at:
// gaato/mttp_ng's serve() with a handler that answers every request.
//
//   GET  /       `OK`
//   ANY  /wait   `OK` after 200 ms, so that the stream is still open when a
//                peer's next frame arrives (h2spec -P /wait)
//   ANY  other   the request body back, with its method in x-method
//
//   server <address> <cert.pem> <key.pem> [h3]
//                serves HTTP/1.1, HTTP/2 and, with `h3`, HTTP/3 over TLS
//   server <address> h2c
//                serves cleartext HTTP/1.1 and HTTP/2 by prior knowledge
//   server version
//                prints `nghttp2 <version>` of the linked library, for
//                h2spec_known.tsv's versions column, and exits
//
// It prints `listening <address>` once bound, and runs until killed.

///|
async fn answer(request : @mttp_core.Request) -> @mttp_core.Response noraise {
  let url = @mttp_core.Url::parse(request.url) catch {
    _ => return @mttp_core.Response::new(400)
  }
  if url.path == "/wait" {
    @async.sleep(200)
    return @mttp_core.Response::new(200, body=Bytes(b"OK"))
  }
  if url.path == "/" && request.meth is Get {
    return @mttp_core.Response::new(200, body=Bytes(b"OK"))
  }
  let body = request.body.read_all(max=1 << 20) catch {
    _ => return @mttp_core.Response::new(400)
  }
  @mttp_core.Response::new(
    200,
    headers=@mttp_core.Headers::of([("x-method", request.meth.to_string())]),
    body=Bytes(body),
  )
}

///|
async fn main {
  let args = @env.args()
  let printed = (address : String) => println("listening \{address}")
  match args[1:].to_owned() {
    ["version"] => {
      let v = @h2.nghttp2_version()
      println("nghttp2 \{(v >> 16) & 0xff}.\{(v >> 8) & 0xff}.\{v & 0xff}")
    }
    [address, "h2c"] =>
      @mttp_ng.serve(answer, addr=address, h2c=true, on_listen=printed)
    [address, cert, key, .. rest] =>
      @mttp_ng.serve(
        answer,
        addr=address,
        cert=@fs.read_text(cert),
        key=@fs.read_text(key),
        h3=rest is ["h3"],
        on_listen=printed,
      )
    _ => {
      println(
        "usage: server <address> <cert.pem> <key.pem> [h3] | server <address> h2c | server version",
      )
      return
    }
  }
}
