// A bound of h2_stub.c that only the C side can show: the memory a
// stream's body queue holds.

///|
#borrow(raw)
extern "C" fn queue_capacity(raw : Raw, stream : Int32) -> Int32 = "mttp_ng_h2_queue_capacity"

///|
/// A body whose reader never quite catches up keeps its queue nonempty: the
/// queue holds what is unsent, not everything that went through it
/// (Codex's review of #58: its consumed prefix was kept until the queue
/// emptied, so a long stream's queue grew by everything it sent).
test "a body queue that never empties holds only what is unsent" {
  let client = H2Session::client()
  defer client.free()
  let server = H2Session::server(settings={
    ..H2Settings::server(),
    stream_window: 10000,
  })
  defer server.free()
  // SETTINGS both ways first: until the client has the server's, it sends
  // up to the default window of 65535 bytes.
  for _ in 0..<3 {
    server.recv(client.output())
    client.recv(server.output())
  }
  ignore(server.events())
  ignore(client.events())
  let id = client.submit_request(
    [
      (":method", "POST"),
      (":scheme", "https"),
      (":authority", "example.com"),
      (":path", "/"),
    ],
    body=true,
  )
  let piece = Bytes::make(10000, b'b')
  // Three pieces queued, then one more each round as the server takes one
  // window's worth: the queue never empties.
  for _ in 0..<3 {
    client.push(id, piece, end=false)
  }
  let mut sent = 0
  for _ in 0..<600 {
    client.push(id, piece, end=false)
    server.recv(client.output())
    for event in server.events() {
      if event is Data(stream~, data) {
        sent += data.length()
        server.consume_connection(data.length())
        server.consume_stream(stream, data.length())
      }
    }
    client.recv(server.output())
    ignore(client.events())
    assert_true(client.queued(id).unwrap_or(0) > 0)
  }
  assert_true(sent >= 5000000, msg="only \{sent} bytes went")
  let capacity = queue_capacity(client.raw, id)
  assert_true(capacity <= 65536, msg="the queue holds \{capacity} bytes")
}
