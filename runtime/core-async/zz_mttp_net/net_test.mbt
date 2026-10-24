///|
async fn rss_kb() -> Int {
  let f = @fs.open("/proc/self/status", mode=ReadOnly)
  defer f.close()
  let text = @utf8.decode_lossy(f.read_all())
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
async fn with_server(
  limits : @zz_mttp_net.ServerLimits,
  f : async (String) -> Unit,
) -> Unit {
  @async.with_task_group(g => {
    let addr : Ref[String] = Ref("")
    let ready = @async.Cond()
    g.spawn_bg(no_wait=true, () => {
      @zz_mttp_net.serve(echo_handler, addr="127.0.0.1:0", limits~, on_listen=a => {
        addr.val = a
        ready.signal()
      })
    })
    if addr.val == "" {
      ready.wait()
    }
    f(addr.val)
    g.return_immediately()
  })
}

///|
async fn raw_exchange(addr : String, request : Bytes) -> String {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse(addr))
  defer tcp.close()
  tcp.write(request)
  let got = @async.with_timeout_opt(3000, () => tcp.read_until(b"\r\n\r\n"))
  match got {
    Some(Some(head)) => {
      let text = @utf8.decode_lossy(head)
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
async test "backend round trip over core-main async (no runtime type in API)" {
  with_server(@zz_mttp_net.ServerLimits::default(), addr => {
    let backend = @zz_mttp_net.AsyncBackend::new(timeout_ms=3000)
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
async test "duplicate Cookie headers: stock parser merges with comma, prescan keeps them" {
  let req = b"GET /c HTTP/1.1\r\nHost: x\r\nCookie: a=1\r\nCookie: b=2\r\nContent-Length: 0\r\n\r\n"
  let stock = { ..@zz_mttp_net.ServerLimits::default(), prescan_head: false }
  with_server(stock, addr => {
    let r = raw_exchange(addr, req)
    inspect(r.contains("cookies=a=1,b=2 "), content="true")
  })
  with_server(@zz_mttp_net.ServerLimits::default(), addr => {
    let r = raw_exchange(addr, req)
    inspect(r.contains("cookies=a=1|b=2 "), content="true")
  })
}

///|
async test "oversize head: 431 with prescan" {
  let big = StringBuilder()
  big.write_string("GET / HTTP/1.1\r\nHost: x\r\nX-Big: ")
  for _ in 0..<20000 {
    big.write_char('a')
  }
  big.write_string("\r\n\r\n")
  with_server(@zz_mttp_net.ServerLimits::default(), addr => {
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
  let after = rss_kb()
  after - before
}

///|
async test "unbounded head line on the stock parser vs prescan (RSS growth, KiB)" {
  let stock = {
    ..@zz_mttp_net.ServerLimits::default(),
    prescan_head: false,
    header_timeout_ms: 20000,
  }
  let mut grown_stock = 0
  with_server(stock, addr => {
    grown_stock = flood(addr, b"GET / HTTP/1.1\r\nX-Big: ", 64)
  })
  let mut grown_prescan = 0
  with_server({ ..@zz_mttp_net.ServerLimits::default(), header_timeout_ms: 20000 }, addr => {
    grown_prescan = flood(addr, b"GET / HTTP/1.1\r\nX-Big: ", 64)
  })
  println("RSS growth, 5 s flood of one header line: stock=\{grown_stock} KiB prescan=\{grown_prescan} KiB")
  inspect(grown_stock > 8000, content="true")
  inspect(grown_prescan < 2000, content="true")
}

///|
async test "unbounded chunk-size line in request body even with prescan (RSS growth, KiB)" {
  let mut grown = 0
  with_server({ ..@zz_mttp_net.ServerLimits::default(), header_timeout_ms: 20000 }, addr => {
    grown = flood(
      addr,
      b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
      32,
    )
  })
  println("RSS growth, 5 s flood of one chunk-size line (max_body 1 KiB in handler): \{grown} KiB")
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
  // a short request then waits for the server to have consumed what it can
  @async.now() - start
}

///|
async test "stock parser ingest time for one header line (quadratic?)" {
  let stock = { ..@zz_mttp_net.ServerLimits::default(), prescan_head: false, header_timeout_ms: 120000 }
  with_server(stock, addr => {
    for kib in [2048, 4096, 8192, 16384] {
      let ms = ingest_ms(addr, b"GET / HTTP/1.1\r\nX-Big: ", kib)
      println("stock core-main: header line \{kib} KiB written in \{ms} ms")
    }
  })
  with_server({ ..@zz_mttp_net.ServerLimits::default(), header_timeout_ms: 120000 }, addr => {
    let ms = ingest_ms(addr, b"GET / HTTP/1.1\r\nX-Big: ", 16384) catch { _ => -1L }
    println("prescan core-main: 16384 KiB attempt ended after \{ms} ms (431 + close)")
  })
}

///|
async fn latency_during_flood(limits : @zz_mttp_net.ServerLimits) -> Int64 {
  let mut latency = -1L
  with_server(limits, addr => {
    @async.with_task_group(g => {
      g.spawn_bg(no_wait=true, () => {
        ignore(ingest_ms(addr, b"GET / HTTP/1.1\r\nX-Big: ", 8192)) catch { _ => () }
      })
      @async.sleep(500)
      let t0 = @async.now()
      let backend = @zz_mttp_net.AsyncBackend::new(timeout_ms=30000)
      let resp = backend.send({
        meth: "GET",
        url: "http://\{addr}/ping",
        headers: @model.Headers::empty(),
        body: Empty,
      })
      guard resp.body is Stream(s, ..) else { return }
      ignore(@model.read_bounded(s, 4096))
      latency = @async.now() - t0
    })
  })
  latency
}

///|
async test "event-loop starvation: GET latency while another client floods a header line" {
  let stock = latency_during_flood({
    ..@zz_mttp_net.ServerLimits::default(),
    prescan_head: false,
    header_timeout_ms: 60000,
  })
  let pre = latency_during_flood({ ..@zz_mttp_net.ServerLimits::default(), header_timeout_ms: 60000 })
  println("GET latency during one-connection header flood: stock=\{stock} ms prescan=\{pre} ms")
}

///|
async test "many-connection header flood within the 5 s header timeout (RSS KiB)" {
  for prescan in [false, true] {
    let limits = { ..@zz_mttp_net.ServerLimits::default(), prescan_head: prescan }
    let mut grown = 0
    let total = @ref.Ref(0)
    with_server(limits, addr => {
      let before = rss_kb()
      let peak = @ref.Ref(before)
      @async.with_task_group(g => {
        g.spawn_bg(no_wait=true, () => {
          for ;; {
            @async.sleep(100)
            let r = rss_kb()
            if r > peak.val {
              peak.val = r
            }
          }
        })
        for _ in 0..<32 {
          g.spawn_bg(allow_failure=true, () => {
            let chunk = Bytes::make(16384, b'a')
            let tcp = @socket.Tcp::connect(@socket.Addr::parse(addr))
            defer tcp.close()
            tcp.write(b"GET / HTTP/1.1\r\nX-Big: ")
            ignore(@async.with_timeout_opt(4000, () => {
              for ;; {
                tcp.write(chunk)
                total.val += 16
              }
            }))
          })
        }
      })
      grown = peak.val - before
    })
    println("32 conns x 4 s header flood, header_timeout 5 s, prescan=\{prescan}: sent \{total.val} KiB, peak RSS growth \{grown} KiB")
  }
}

///|
async test "disconnect detection with a background peek (core-main only)" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let addr = server.addr.to_string()
  let log : Array[String] = []
  @async.with_task_group(g => {
    g.spawn_bg(() => {
      let (tcp, _) = server.accept()
      let conn = @ahttp.ServerConnection::new(tcp)
      defer conn.close()
      let req = conn.read_request()
      conn.skip_request_body()
      log.push("got \{req.path}")
      let t0 = @async.now()
      @async.with_task_group(h => {
        h.spawn_bg(no_wait=true, () => {
          // EOF from the client while the handler runs: cancel the handler
          if tcp.peek() is None {
            log.push("peer closed after \{@async.now() - t0} ms; cancelling handler")
            h.return_immediately()
          }
        })
        @async.sleep(3000) // the "handler"
        log.push("handler finished (should not happen)")
      })
    })
    let c = @socket.Tcp::connect(@socket.Addr::parse(addr))
    c.write(b"GET /slow HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
    @async.sleep(100)
    c.close()
  })
  println(log.join("\n"))
  inspect(log.length(), content="2")
}

///|
async test "CL+TE request on the stock parser: connection kept open (RFC 9112 6.3 says MUST close)" {
  let stock = { ..@zz_mttp_net.ServerLimits::default(), prescan_head: false }
  with_server(stock, addr => {
    let tcp = @socket.Tcp::connect(@socket.Addr::parse(addr))
    defer tcp.close()
    tcp.write(
      b"POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 30\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /smuggled HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n",
    )
    let buf = StringBuilder()
    ignore(@async.with_timeout_opt(1000, () => {
      while tcp.read() is Some(chunk) {
        buf.write_string(@utf8.decode_lossy(chunk))
      }
    }))
    let text = buf.to_string()
    println("responses: \{text.split("HTTP/1.1 200").collect().length() - 1}; smuggled seen: \{text.contains("/smuggled")}")
  })
}
