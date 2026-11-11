///|
priv struct RecoveringOutput {
  body : @mttp.Body
  fallback : Bool
  failure : Ref[@mttp.TransportError?]
  mut reads : Int32
  mut closes : Int32
}

///|
impl @mttp.BodyStream for RecoveringOutput with fn read_some(self) {
  self.reads += 1
  if self.reads > 1 {
    return None
  }
  if self.body is Stream(cell) {
    ignore(@mttp.read_bounded(cell.take(), 10)) catch {
      error => self.failure.val = Some(error)
    }
  }
  if self.fallback {
    Some(b"fallback")
  } else {
    None
  }
}

///|
impl @mttp.BodyStream for RecoveringOutput with fn close(self) {
  self.closes += 1
}

///|
async test "listener preserves caught request failures after response prefetch" {
  for fallback in [false, true] {
    let source : Ref[RecoveringOutput?] = Ref(None)
    let failure : Ref[@mttp.TransportError?] = Ref(None)
    let errors : Array[@mttp.TransportError] = []
    with_server(
      request => {
        let output = RecoveringOutput::{
          body: request.body,
          fallback,
          failure,
          reads: 0,
          closes: 0,
        }
        source.val = Some(output)
        @mttp.Response::new(201, body=Stream(@mttp.StreamBody::new(output)))
      },
      address => {
        for
          (chunks, status) in [
            ("3\r\nabc\r\n0\r\n\r\n", 413),
            ("bad-chunk\r\n", 400),
          ] {
          failure.val = None
          errors.clear()
          let response = raw(
            address,
            @mttp.encode_utf8(
              "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" +
              chunks,
            ),
          )
          assert_true(response.has_prefix("HTTP/1.1 \{status} "), msg=response)
          assert_eq(response.split("HTTP/1.1 ").count(), 2)
          assert_false(response.contains("fallback"))
          assert_true(failure.val is Some(_))
          assert_eq(errors.length(), 1)
          if status == 413 {
            assert_true(
              errors[0]
              is @mttp.TransportError(kind=TooLarge(limit=2), phase=Body, ..),
            )
          } else {
            assert_true(
              errors[0] is @mttp.TransportError(kind=Protocol, phase=Body, ..),
            )
          }
          assert_eq(source.val.unwrap().reads, 1)
          assert_eq(source.val.unwrap().closes, 1)
        }
      },
      limits={ ..@h1server.ServerLimits::default(), max_body_bytes: 2, },
      on_error=error => errors.push(error),
    )
  }
}
