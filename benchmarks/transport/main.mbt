///|
let small_body : Bytes = b"mttp benchmark\n"

///|
let large_body : Bytes = Bytes::from_array(Array::make(1024 * 1024, b'x'))

///|
fn body_named(name : String) -> Bytes {
  match name {
    "small" => small_body
    "large" => large_body
    _ => abort("unknown body: \{name}")
  }
}

///|
fn body_for_path(path : String) -> Bytes? {
  if path.has_suffix("/small") {
    Some(small_body)
  } else if path.has_suffix("/large") {
    Some(large_body)
  } else {
    None
  }
}

///|
async fn serve_mttp(addr : String) -> Unit {
  @server.serve(
    request => {
      match body_for_path(request.url) {
        Some(body) =>
          @mttp_core.Response::new(
            200,
            headers=@mttp_core.Headers::of([
              ("content-type", "application/octet-stream"),
            ]),
            body=Bytes(body),
          )
        None => @mttp_core.Response::new(404, body=Bytes(b"not found\n"))
      }
    },
    addr~,
    auto_date=true,
    on_listen=bound => println("READY\tserver\tmttp\t\{bound}"),
  )
}

///|
async fn serve_core(addr : String) -> Unit {
  let server = @http.Server(@socket.Addr::parse(addr), reuse_addr=true, headers={
    "Date": @mttp_core.format_http_date(@env.now().reinterpret_as_int64()),
  })
  defer server.close()
  println("READY\tserver\tcore\t\{addr}")
  server.run_forever((request, conn) => {
    match body_for_path(request.path) {
      Some(body) => {
        conn.send_response(200, "OK", extra_headers={
          "Content-Length": body.length().to_string(),
          "Content-Type": "application/octet-stream",
        })
        conn.write(body)
        conn.end_response()
      }
      None => {
        let body = b"not found\n"
        conn.send_response(404, "Not Found", extra_headers={
          "Content-Length": body.length().to_string(),
          "Content-Type": "application/octet-stream",
        })
        conn.write(body)
        conn.end_response()
      }
    }
  })
}

///|
async fn read_mttp(response : @mttp_core.Response) -> Bytes {
  defer response.close()
  guard response.status == 200 else {
    fail("unexpected mttp response status: \{response.status}")
  }
  match response.body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(cell) => @mttp_core.read_bounded(cell.take(), 1024 * 1024 + 1)
    @mttp_core.Body::.. => fail("unsupported response body")
  }
}

///|
async fn check_body(url : String, expected : Bytes) -> Unit {
  let backend = @backend.AsyncBackend::new(
    config=@h1client.ClientConfig::default(),
  )
  defer backend.close()
  let actual = read_mttp(
    backend.send(
      @mttp_core.Request::get(url),
      @mttp_core.SendOptions::default(),
    ),
  )
  if actual != expected {
    fail(
      "wrong body from \{url}: got \{actual.length()} bytes, expected \{expected.length()}",
    )
  }
  println("CHECK\tok\t\{url}\tbytes=\{actual.length()}")
}

///|
async fn mttp_worker(
  url : String,
  expected : Bytes,
  running : Ref[Bool],
  latencies_us : Array[Double],
) -> Unit {
  let backend = @backend.AsyncBackend::new(
    config=@h1client.ClientConfig::default(),
  )
  defer backend.close()
  let request = @mttp_core.Request::get(url)
  while running.val {
    let started = @bench.monotonic_clock_start()
    let actual = read_mttp(
      backend.send(request, @mttp_core.SendOptions::default()),
    )
    let latency = @bench.monotonic_clock_end(started)
    if actual != expected {
      fail(
        "wrong body from \{url}: got \{actual.length()} bytes, expected \{expected.length()}",
      )
    }
    latencies_us.push(latency)
  }
}

///|
async fn core_worker(
  base : String,
  path : String,
  expected : Bytes,
  running : Ref[Bool],
  latencies_us : Array[Double],
) -> Unit {
  let conn = @http.ClientConnection(base)
  defer conn.close()
  while running.val {
    let started = @bench.monotonic_clock_start()
    conn.request(@http.Get, path)
    let response = conn.end_request()
    let actual = conn.read_all()
    let latency = @bench.monotonic_clock_end(started)
    if response.code != 200 {
      fail("unexpected core/async/http response status: \{response.code}")
    }
    if actual != expected {
      fail(
        "wrong body from \{base}\{path}: got \{actual.length()} bytes, expected \{expected.length()}",
      )
    }
    latencies_us.push(latency)
  }
}

///|
fn percentile(sorted : Array[Double], percent : Int32) -> Double {
  guard !sorted.is_empty() else { abort("no completed requests") }
  sorted[(sorted.length() - 1) * percent / 100]
}

///|
async fn run_client(
  implementation : String,
  base : String,
  body_name : String,
  concurrency : Int32,
  duration_ms : Int32,
) -> Unit {
  let expected = body_named(body_name)
  let path = "/\{body_name}"
  let running = Ref(true)
  let latencies_us : Array[Double] = []
  let started = @bench.monotonic_clock_start()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      @async.sleep(duration_ms)
      running.val = false
    })
    for _ in 0..<concurrency {
      match implementation {
        "mttp" =>
          group.spawn_bg(() => {
            mttp_worker("\{base}\{path}", expected, running, latencies_us)
          })
        "core" =>
          group.spawn_bg(() => {
            core_worker(base, path, expected, running, latencies_us)
          })
        _ => abort("unknown client implementation: \{implementation}")
      }
    }
  })
  let elapsed_us = @bench.monotonic_clock_end(started)
  latencies_us.sort()
  let requests_per_second = latencies_us.length().to_double() /
    (elapsed_us / 1_000_000.0)
  println(
    "CLIENT_RESULT\t\{implementation}\t\{body_name}\t\{concurrency}\t\{requests_per_second}\t\{percentile(latencies_us, 50) / 1000.0}\t\{percentile(latencies_us, 99) / 1000.0}\t\{latencies_us.length()}",
  )
}

///|
fn usage() -> Unit {
  println(
    "usage: transport build | server <mttp|core> <address> | check <url> <small|large> | client <mttp|core> <base-url> <small|large> <concurrency> <duration-ms>",
  )
  @env.exit(2)
}

///|
async fn main {
  let args = @env.args()
  match args {
    [_, "build"] => ()
    [_, "server", "mttp", addr] => serve_mttp(addr)
    [_, "server", "core", addr] => serve_core(addr)
    [_, "check", url, body_name] => check_body(url, body_named(body_name))
    [_, "client", implementation, base, body_name, concurrency, duration_ms] =>
      run_client(
        implementation,
        base,
        body_name,
        @string.parse_int(concurrency),
        @string.parse_int(duration_ms),
      )
    _ => usage()
  }
}
