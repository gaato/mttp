///|
async fn rss_kb() -> Int {
  let text = @fs.read_file("/proc/self/status").text()
  for line in text.split("\n") {
    if line.has_prefix("VmRSS:") {
      let digits = StringBuilder()
      for c in line {
        if c >= '0' && c <= '9' {
          digits.write_char(c)
        }
      }
      return @string.parse_int(digits.to_string()) catch { _ => -1 }
    }
  }
  -1
}

///|
let echo_handler : @model.Handler = async fn(req) noraise {
  let body = match req.body {
    Stream(s, ..) =>
      @model.read_bounded(s, 1024) catch {
        _ => b"<body error>"
      }
    Bytes(b) => b
    _ => b""
  }
  let cookies = req.headers.get_all("cookie").join("|")
  let text = "\{req.meth} \{req.url} cookies=\{cookies} body=\{@utf8.decode_lossy(body)}"
  Respond({
    status: 200,
    headers: @model.Headers::of([("set-cookie", "a=1"), ("set-cookie", "b=2")]),
    body: Bytes(@utf8.encode(text)),
    close_connection: false,
  })
}

///|
async fn with_server(limits : @net.ServerLimits, f : async (String) -> Unit) -> Unit {
  // 0.22.5: TaskGroup[X], return_immediately(x), CondVar
  @async.with_task_group(g => {
    let addr : Ref[String] = Ref("")
    let ready : @async.CondVar = @cond_var.Cond()
    g.spawn_bg(no_wait=true, () => {
      @net.serve(echo_handler, addr="127.0.0.1:0", limits~, on_listen=a => {
        addr.val = a
        ready.signal()
      })
    })
    if addr.val == "" {
      ready.wait()
    }
    f(addr.val)
    g.return_immediately(())
  })
}

///|
async fn raw_exchange(addr : String, request : Bytes) -> String {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse(addr))
  defer tcp.close()
  tcp.write(request)
  let got = @async.with_timeout_opt(3000, () => tcp.read_until("\r\n\r\n"))
  match got {
    Some(Some(text)) => {
      let n = match text.find("Content-Length: ") {
        Some(i) => {
          let rest = text[i + 16:]
          let end = rest.find("\r\n").unwrap_or(rest.length())
          @string.parse_int(rest[:end]) catch { _ => 0 }
        }
        None => 0
      }
      let body = if n > 0 { tcp.read_exactly(n) } else { b"" }
      text + "\n\n" + @utf8.decode_lossy(body)
    }
    _ => "<no response>"
  }
}

///|
async test "backend round trip over 0.22.5" {
  with_server(@net.ServerLimits::default(), addr => {
    let backend = @net.AsyncBackend::new(timeout_ms=3000)
    let resp = backend.send({
      meth: "POST",
      url: "http://\{addr}/echo?x=1",
      headers: @model.Headers::of([("content-type", "text/plain")]),
      body: Bytes(b"hello"),
    })
    guard resp.body is Stream(s, ..) else { fail("no stream") }
    let body = @model.read_bounded(s, 4096)
    inspect(resp.status, content="200")
    inspect(resp.headers.get_all("set-cookie").join("|"), content="a=1|b=2")
    inspect(@utf8.decode_lossy(body), content="POST /echo?x=1 cookies= body=hello")
  })
}

///|
async test "duplicate Cookie: stock 0.22.5 parser merges, own codec keeps" {
  let req = b"GET /c HTTP/1.1\r\nHost: x\r\nCookie: a=1\r\nCookie: b=2\r\nContent-Length: 0\r\n\r\n"
  with_server({ ..@net.ServerLimits::default(), prescan_head: false }, addr => {
    let r = raw_exchange(addr, req)
    inspect(r.contains("cookies=a=1,b=2 "), content="true")
  })
  with_server(@net.ServerLimits::default(), addr => {
    let r = raw_exchange(addr, req)
    inspect(r.contains("cookies=a=1|b=2 "), content="true")
  })
}

///|
async test "oversize head: 431 from own codec on 0.22.5" {
  let big = StringBuilder()
  big.write_string("GET / HTTP/1.1\r\nHost: x\r\nX-Big: ")
  for _ in 0..<20000 {
    big.write_char('a')
  }
  big.write_string("\r\n\r\n")
  with_server(@net.ServerLimits::default(), addr => {
    let r = raw_exchange(addr, @utf8.encode(big.to_string()))
    inspect(r.has_prefix("HTTP/1.1 431"), content="true")
  })
}

///|
async fn flood(addr : String, prefix : Bytes, mib : Int) -> Int {
  let chunk = Bytes::make(65536, b'a')
  let before = rss_kb()
  let tcp = @socket.Tcp::connect(@socket.Addr::parse(addr))
  defer tcp.close()
  tcp.write(prefix)
  let mut written = 0
  let sent = @async.with_timeout_opt(5000, () => {
    for _ in 0..<(mib * 16) {
      tcp.write(chunk)
      written += 1
    }
  }) catch { e => { println("flood write error: \{e}"); None } }
  println("flood: wrote \{written * 64} KiB, finished=\{sent is Some(_)}")
  @async.sleep(300)
  rss_kb() - before
}

///|
async test "unbounded head line on 0.22.5 stock parser vs own codec (RSS KiB)" {
  let mut stock = 0
  with_server({ ..@net.ServerLimits::default(), prescan_head: false, header_timeout_ms: 20000 }, addr => {
    stock = flood(addr, b"GET / HTTP/1.1\r\nX-Big: ", 64)
  })
  let mut own = 0
  with_server({ ..@net.ServerLimits::default(), header_timeout_ms: 20000 }, addr => {
    own = flood(addr, b"GET / HTTP/1.1\r\nX-Big: ", 64)
  })
  println("0.22.5 RSS growth, 5 s flood of one header line: stock=\{stock} KiB own_codec=\{own} KiB")
  inspect(stock > 8000, content="true")
  inspect(own < 2000, content="true")
}

///|
async test "unbounded chunk-size line on 0.22.5 stock parser (RSS KiB)" {
  let mut grown = 0
  with_server({ ..@net.ServerLimits::default(), prescan_head: false, header_timeout_ms: 20000 }, addr => {
    grown = flood(addr, b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", 64)
  })
  println("0.22.5 RSS growth, 5 s flood of one chunk-size line: \{grown} KiB")
  inspect(grown > 8000, content="true")
}

///|
async fn ingest_ms(addr : String, prefix : Bytes, kib : Int) -> Int64 {
  let chunk = Bytes::make(1024, b'a')
  let tcp = @socket.Tcp::connect(@socket.Addr::parse(addr))
  defer tcp.close()
  tcp.write(prefix)
  let start = @async.now()
  for _ in 0..<kib {
    tcp.write(chunk)
  }
  @async.now() - start
}

///|
async test "0.22.5 stock parser ingest time for one header line (quadratic?)" {
  let stock = { ..@net.ServerLimits::default(), prescan_head: false, header_timeout_ms: 120000 }
  with_server(stock, addr => {
    for kib in [2048, 4096, 8192, 16384] {
      let ms = ingest_ms(addr, b"GET / HTTP/1.1\r\nX-Big: ", kib)
      println("stock 0.22.5: header line \{kib} KiB written in \{ms} ms")
    }
  })
}
