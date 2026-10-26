///|
async test "head and body truncation are reported even when the peer cannot receive an error" {
  for partial_head in [true, false] {
    let errors : Array[@server.ServeError] = []
    let wake = @cond_var.Cond()
    with_server(
      req => {
        ignore(@client.read_body(req.body, 1024) catch { _ => b"" })
        @model.Response::new(200)
      },
      address => {
        let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
        tcp.write(
          if partial_head {
            b"GET / HTTP/1.1\r\nHost:"
          } else {
            b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nx"
          },
        )
        tcp.close()
        while errors.is_empty() {
          wake.wait()
        }
        assert_true(errors[0].kind is Protocol)
      },
      on_error=error => {
        errors.push(error)
        wake.signal()
      },
    )
  }
}

///|
async test "invalid framing output metadata and compression weights refuse the exchange" {
  with_server(
    req => {
      if req.url.has_suffix("/status") {
        return @model.Response::new(100)
      }
      if req.url.has_suffix("/taken") {
        let body = @model.StreamBody::new(LargeReply::{ remaining: Some(b"x"), })
        ignore(body.take() catch { _ => return @model.Response::new(500) })
        return @model.Response::new(200, body=Stream(body))
      }
      if req.url.has_suffix("/header") {
        return @model.Response::new(
          200,
          headers=@model.Headers::of([("bad\n", "value")]),
        )
      }
      @model.Response::new(200, body=Bytes(b"ok"))
    },
    address => {
      for
        (request, status) in [
          (
            b"GET /taken HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n",
            "500",
          ),
          (
            b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "400",
          ),
          (
            b"GET /status HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", "500",
          ),
          (
            b"GET /header HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", "500",
          ),
          (
            b"GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip;q=bad\r\nConnection: close\r\n\r\n",
            "400",
          ),
        ] {
        assert_true(raw(address, request).has_prefix("HTTP/1.1 " + status))
      }
      assert_true(
        raw(
          address, b"GET http://example.test/absolute HTTP/1.1\r\nHost: other\r\nConnection: close\r\n\r\n",
        ).has_suffix("ok"),
      )
    },
    compression=true,
  )
}

///|
async test "lazy request echoes preserve input error statuses before response headers" {
  with_server(
    req => @model.Response::new(200, body=req.body),
    address => {
      for
        (chunk, status) in [
          ("4\r\nabcd\r\n0\r\n\r\n", "413"),
          ("wrong\r\n", "400"),
          ("", "408"),
        ] {
        let request = @model.encode_utf8(
          "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" +
          chunk,
        )
        assert_true(raw(address, request).has_prefix("HTTP/1.1 " + status))
      }
    },
    limits={
      ..@server.ServerLimits::default(),
      max_body_bytes: 3,
      body_timeout_ms: 30,
    },
  )
}
