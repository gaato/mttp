///|
/// Runs a deterministic async computation, refusing unsupported suspension
/// and unwinding its tasks before returning. See testing/driver for virtual
/// time and explicit scheduling.
pub using @driver {run_sync}

///|
/// Checks that a parser's value is invariant under every two-part split and
/// byte-at-a-time input, including empty prefix and suffix chunks. Normalize
/// expected parser errors into the returned value to compare error kinds too.
pub fn[T : Eq + @debug.Debug] check_splits(
  input : Bytes,
  parse : (Array[Bytes]) -> T raise,
) -> Unit raise {
  let expected = parse([input])
  for cut in 0..<=input.length() {
    assert_eq(
      parse([input[:cut].to_owned(), input[cut:].to_owned()]),
      expected,
      msg="parser differs at split \{cut}",
    )
  }
  assert_eq(
    parse(Array::makei(input.length(), i => input[i:i + 1].to_owned())),
    expected,
    msg="parser differs for single-byte chunks",
  )
}

///|
/// Checks invalid-input rejection and idempotent close on a fresh backend.
/// `url` can name a local fixture; malformed inputs must be refused before
/// network I/O. This suite does not establish transport-specific deadlines,
/// decompression or header fidelity, which need configured response fixtures.
pub async fn check_backend_contract(
  make : () -> &@client.Backend,
  url~ : String = "https://example.test/",
) -> Array[String] {
  let failures = []
  let backend = make()
  defer backend.close()
  for
    request in [
      @model.Request::get(url + "\r\n"),
      @model.Request::get(url).header("x-test", "one\ntwo"),
      @model.Request::get(url).header("bad name", "value"),
    ] {
    try {
      let response = backend.send(request, @client.RequestOptions::default())
      response.close()
      failures.push("invalid request accepted")
    } catch {
      @model.TransportError(kind=Invalid, ..) => ()
      _ => failures.push("invalid request has wrong error kind")
    }
  }
  backend.close()
  backend.close()
  try {
    let response = backend.send(
      @model.Request::get(url),
      @client.RequestOptions::default(),
    )
    response.close()
    failures.push("closed backend accepted a request")
  } catch {
    @model.TransportError(kind=Closed, ..) => ()
    _ => failures.push("closed backend has wrong error kind")
  }
  failures
}

///|
/// Checks a finite stream fixture against expected bytes, nonempty chunks,
/// sticky EOF and idempotent close. `max_reads` stops a faulty fixture that
/// emits indefinitely; each individual read still needs its adapter's timer.
pub async fn check_body_stream_contract(
  make : () -> &@model.BodyStream,
  expected : Bytes,
  max_reads~ : Int32 = 1024,
) -> Array[String] {
  let failures = []
  let stream = make()
  defer stream.close()
  let actual = Buffer()
  let mut ended = false
  for _ in 0..<max_reads.max(0) {
    match stream.read_some() {
      None => {
        ended = true
        break
      }
      Some(chunk) => {
        if chunk.is_empty() {
          failures.push("empty body chunk")
          break
        }
        if chunk.length() > expected.length() - actual.length() {
          failures.push("body exceeds expected bytes")
          break
        }
        actual.write_bytes(chunk)
      }
    }
  }
  if !ended {
    failures.push("stream did not reach EOF within read budget")
  }
  if actual.to_bytes() != expected {
    failures.push("body bytes differ")
  }
  if ended && stream.read_some() is Some(_) {
    failures.push("EOF is not sticky")
  }
  stream.close()
  stream.close()
  if stream.read_some() is Some(_) {
    failures.push("read after close is not EOF")
  }
  failures
}
