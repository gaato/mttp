///|
async fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    println("usage: get <url>")
    @env.exit(2)
  }
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  let response = backend.send(@mttp.Request::get(args[1]), {
    timeout_ms: Some(30000),
    body: Exchange(max_bytes=64 * 1024 * 1024),
  })
  defer response.close()
  println("status: \{response.status}")
  for (name, value) in response.headers.iter() {
    println("\{name}: \{value}")
  }
  let length = match response.body {
    Empty => 0
    Bytes(bytes) => bytes.length()
    Stream(cell) => @mttp.read_bounded(cell.take(), 64 * 1024 * 1024).length()
    @mttp.Body::.. => abort("unsupported body kind")
  }
  println("decoded body length: \{length}")
}
