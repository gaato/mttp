///|
async test "handler deadline cleans up a suspended handler after peer EOF" {
  let entered = Ref(false)
  let cleaned = Ref(false)
  let wake = @cond_var.Cond()
  with_server(
    _ => {
      defer {
        cleaned.val = true
        wake.broadcast()
      }
      entered.val = true
      wake.broadcast()
      @async.sleep(10000)
      @model.Response::new(200)
    },
    address => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      while !entered.val {
        wake.wait()
      }
      tcp.close()
      @async.with_timeout(1000, () => {
        while !cleaned.val {
          wake.wait()
        }
      })
    },
    limits={ ..@server.ServerLimits::default(), handler_timeout_ms: Some(100), },
  )
  assert_true(cleaned.val)
}

///|
async test "a client write-half close preserves delayed and streamed replies" {
  with_server(
    request => {
      let bytes = @client.read_body(request.body, 32) catch {
        _ => return @model.Response::new(400)
      }
      // Suspend so that the peer monitor observes FIN before we respond.
      @async.sleep(100)
      @model.Response::new(
        200,
        body=Stream(
          @model.StreamBody::new(
            DelayedReply::{ bytes, offset: 0, },
            length=bytes.length().to_int64(),
          ),
        ),
      )
    },
    address => {
      @shell.Cmd("node", ["src/server/fixtures/half_close.mjs", address]).run(
        timeout_ms=3000,
      )
    },
  )
}

///|
priv struct DelayedReply {
  bytes : Bytes
  mut offset : Int32
}

///|
impl @model.BodyStream for DelayedReply with fn read_some(self) {
  if self.offset == self.bytes.length() {
    return None
  }
  @async.sleep(20)
  let byte = self.bytes[self.offset:self.offset + 1].to_owned()
  self.offset += 1
  Some(byte)
}

///|
impl @model.BodyStream for DelayedReply with fn close(self) {
  self.offset = self.bytes.length()
}
