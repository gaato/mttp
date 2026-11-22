// The local server of the tests: testdata/h2_server.mjs on Node, which says
// what each path does. Everything binds 127.0.0.1, so no test needs the
// network.

///|
/// HTTP/2 without ALPN, cleartext included: what the h2c listener needs.
const CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE = 5

///|
/// The listeners of one server process.
priv struct Server {
  h2c : String
  tls : String
}

///|
/// A file of testdata/, from wherever moon runs the tests.
async fn testdata(name : String) -> String {
  for dir in ["testdata", "src/testdata", "mttp_curl/src/testdata"] {
    if @fs.exists("\{dir}/\{name}") {
      return @fs.realpath("\{dir}/\{name}")
    }
  }
  fail("no testdata/\{name} below the working directory")
}

///|
/// Runs `run` against a fresh server, bounded so that a hang fails the test
/// instead of the suite. `max_streams` sets its concurrent-stream limit.
async fn with_server(
  run : async (Server) -> Unit,
  max_streams? : Int32,
) -> Unit {
  let script = testdata("h2_server.mjs")
  let args = [script]
  if max_streams is Some(n) {
    args.push("--max-streams")
    args.push(n.to_string())
  }
  @async.with_timeout(30000, () => {
    @async.with_task_group(group => {
      let (stdin, feed) = @process.write_to_process()
      let (out, stdout) = @process.read_from_process()
      let child = @process.spawn(
        group,
        "node",
        args,
        stdin=Shared(stdin),
        stdout=Shared(stdout),
      )
      defer {
        // The server ends when its stdin closes.
        feed.close()
        out.close()
        child.cancel()
      }
      guard out.read_until(b"\n") is Some(line) else {
        fail("the test server printed no ports")
      }
      let ports = @json.parse(@utf8.decode_lossy(line))
      guard ports is { "h2c": Number(h2c, ..), "tls": Number(tls, ..), .. } else {
        fail("unexpected ports line: \{ports.stringify()}")
      }
      run({
        h2c: "http://127.0.0.1:\{h2c.to_int()}",
        tls: "https://localhost:\{tls.to_int()}",
      })
      group.return_immediately()
    })
  })
}

///|
/// A backend speaking HTTP/2 to the h2c listener.
fn h2c_backend() -> CurlBackend {
  CurlBackend::with_version(
    CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE,
    http3=false,
    trust=System,
  )
}

///|
/// A backend trusting the test root, for the TLS listener.
async fn tls_backend() -> CurlBackend {
  CurlBackend::new(trust=PemFile(testdata("root.pem")))
}

///|
/// The whole body of `response`, at most 16 MiB.
async fn text(response : @mttp_core.Response) -> String {
  @utf8.decode_lossy(response.body.read_all(max=16 << 20))
}
