///|
priv struct ReplyStream {
  mut step : Int32
  failure : Bool
  closes : Ref[Int32]
  mut closed : Bool
}

///|
impl @model.BodyStream for ReplyStream with fn read_some(self) {
  if self.closed {
    return None
  }
  if self.failure {
    raise @model.TransportError(
      kind=Network,
      phase=Body,
      detail="producer failure",
    )
  }
  self.step += 1
  match self.step {
    1 => Some(b"one")
    2 => Some(b"two")
    _ => None
  }
}

///|
impl @model.BodyStream for ReplyStream with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes.val += 1
  }
}

///|
async test "stream replies preserve chunks and duplicate fields and close on HEAD or first-read failure" {
  let closes = Ref(0)
  with_server(
    request => {
      @model.Response::new(
        200,
        headers=@model.Headers::of([
          ("set-cookie", "a=1"),
          ("set-cookie", "b=2"),
        ]),
        body=Stream(
          @model.StreamBody::new(
            ReplyStream::{
              step: 0,
              failure: request.url.has_suffix("/fail"),
              closes,
              closed: false,
            },
            length?=if request.url.has_suffix("/fixed") {
              Some(6L)
            } else {
              None
            },
          ),
        ),
      )
    },
    address => {
      let result = raw(
        address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_true(result.contains("transfer-encoding: chunked"))
      assert_true(result.contains("set-cookie: a=1\r\nset-cookie: b=2"))
      assert_true(result.has_suffix("3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n"))
      let result = raw(
        address, b"HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_false(result.contains("one"))
      assert_false(result.contains("transfer-encoding"))
      let result = raw(
        address, b"GET /fixed HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_true(result.contains("content-length: 6"))
      assert_true(result.has_suffix("onetwo"))
      assert_true(
        raw(
          address, b"GET /fail HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        ).has_prefix("HTTP/1.1 500"),
      )
    },
  )
  assert_eq(closes.val, 4)
}

///|
async test "chunked requests preserve pipelining and reject invalid framing" {
  with_server(
    request => {
      let bytes = @client.read_body(request.body, 1024) catch { _ => b"caught" }
      @model.Response::new(200, body=Bytes(bytes))
    },
    address => {
      let result = raw(
        address, b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n2\r\nbc\r\n0\r\nX-Trailer: yes\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_eq(result.split("HTTP/1.1 200").count(), 3)
      assert_true(result.contains("\r\n\r\nabcHTTP/1.1"))
      assert_true(
        raw(
          address, b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\ninvalid\r\n",
        ).has_prefix("HTTP/1.1 400"),
      )
    },
  )
}

///|
async test "compression respects identity exclusions no-transform and representation validators" {
  with_server(
    request => {
      let headers = @model.Headers::of([
        ("vary", "Accept-Encoding"),
        ("etag", "\"original\""),
        ("content-md5", "old"),
        ("content-digest", "old"),
      ])
      let headers = if request.url.has_suffix("/plain") {
        headers.set("cache-control", "no-transform")
      } else {
        headers
      }
      @model.Response::new(200, headers~, body=Bytes(b"hello"))
    },
    address => {
      let identity = raw(
        address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_true(identity.has_suffix("hello"))
      let refused = raw(
        address, b"GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: *;q=0\r\nConnection: close\r\n\r\n",
      )
      assert_true(refused.has_prefix("HTTP/1.1 406"))
      let plain = raw(
        address, b"GET /plain HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n",
      )
      assert_false(plain.contains("content-encoding"))
      assert_true(plain.has_suffix("hello"))
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(
        b"GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n",
      )
      let head = tcp.read_until("\r\n\r\n").unwrap()
      assert_true(head.contains("content-encoding: gzip"))
      assert_true(head.contains("etag: W/\"original\""))
      assert_true(head.contains("vary: Accept-Encoding"))
      assert_false(head.contains("content-md5"))
      assert_false(head.contains("content-digest"))
    },
    compression=true,
  )
}
