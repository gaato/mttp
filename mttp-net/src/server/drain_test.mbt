///|
async test "drain limits include parsed chunks left after a partial handler read" {
  let calls = Ref(0)
  with_server(
    req => {
      calls.val += 1
      if req.body is Stream(stream) {
        let reader = stream.take() catch {
          _ => return @model.Response::new(500)
        }
        ignore(reader.read_some() catch { _ => None })
        reader.close()
      }
      @model.Response::new(204)
    },
    address => {
      let response = raw(
        address, b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n5\r\nabcde\r\n0\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_eq(response.split("HTTP/1.1 204").count(), 2)
      assert_eq(calls.val, 1)
    },
    limits={ ..@server.ServerLimits::default(), drain_max_bytes: 3, },
  )
}
