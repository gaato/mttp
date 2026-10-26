///|
priv struct LargeReply {
  mut remaining : Bytes?
}

///|
impl @model.BodyStream for LargeReply with fn read_some(self) {
  let bytes = self.remaining
  self.remaining = None
  bytes
}

///|
impl @model.BodyStream for LargeReply with fn close(self) {
  self.remaining = None
}

///|
async test "large response chunks are framed in at most 64 KiB pieces" {
  with_server(
    _ => {
      @model.Response::new(
        200,
        body=Stream(
          @model.StreamBody::new(LargeReply::{
            remaining: Some(Bytes::make(131073, b'x')),
          }),
        ),
      )
    },
    address => {
      let result = raw(
        address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_eq(result.split("10000\r\n").count(), 3)
      assert_true(result.has_suffix("\r\n1\r\nx\r\n0\r\n\r\n"))
    },
  )
}

///|
async test "streamed request echo obeys the adapter limit at the exact boundary" {
  let payload = Bytes::make(131073, b'x')
  with_server(
    request => @model.Response::new(200, body=request.body),
    address => {
      let backend = @backend.H1Backend::new(trust_env=false)
      defer backend.close()
      let response = backend.send(
        @model.Request::post("http://" + address + "/").body_bytes(payload),
        @client.RequestOptions::default(),
      ) catch {
        error => raise Failure("exact-boundary upload: " + error.message())
      }
      assert_eq(@client.read_body(response.body, payload.length()), payload)
      response.close()
      let refused = raw(
        address,
        @model.encode_utf8(
          "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: " +
          (payload.length() + 1).to_string() +
          "\r\n\r\n",
        ),
      )
      assert_true(refused.has_prefix("HTTP/1.1 413"))
      let rejected = backend.send(
        @model.Request::post("http://" + address + "/").body_bytes(
          payload + b"x",
        ),
        @client.RequestOptions::default(),
      )
      assert_eq(rejected.status, 413)
      rejected.close()
    },
    limits={
      ..@server.ServerLimits::default(),
      max_body_bytes: payload.length(),
    },
  )
}
