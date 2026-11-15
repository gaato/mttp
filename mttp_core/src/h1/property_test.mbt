// Property tests of the codec over generated messages (wire_gen_test.mbt):
// writer and reader round trips, split invariance, totality on damaged and
// arbitrary bytes, and agreement between the writer and the reader on the
// language they accept. Every property runs a fixed range of seeds, so a
// failure names a seed that reproduces it on every target.

///|
/// Runs `check` for seeds `0..<count`, naming the seed of a failure.
fn for_seeds(count : UInt64, check : (UInt64) -> Unit raise) -> Unit raise {
  for seed in 0UL..<count {
    check(seed) catch {
      error => fail("seed \{seed}: \{error}")
    }
  }
}

///|
/// `fields` as the codec reads them: names lowercased, values exact, order
/// and duplicates kept.
fn read_as(fields : Array[(String, String)]) -> @mttp_core.Headers {
  @mttp_core.Headers::of(fields)
}

///|
/// The framing a writer is given for a generated body.
fn writer_framing(body : GenBody, close~ : Bool) -> @h1.Framing {
  match body {
    Absent if close => UntilClose
    Absent => NoBody
    Sized(bytes) => Length(bytes.length().to_int64())
    Chunks(..) => Chunked
  }
}

///|
/// The fields a writer emits for `framing`, after the caller's.
fn framing_pairs(
  framing : @h1.Framing,
  empty_length~ : Bool,
) -> Array[(String, String)] {
  match framing {
    NoBody if empty_length => [("content-length", "0")]
    Length(n) => [("content-length", n.to_string())]
    Chunked => [("transfer-encoding", "chunked")]
    UntilClose => [("connection", "close")]
    _ => []
  }
}

///|
test "written request heads parse back to the same request" {
  let requests = gen_request()
  for_seeds(200, seed => {
    let request = requests.sample(seed~)
    let framing = writer_framing(request.body, close=false)
    let head = @h1.write_request_head(
      request.meth,
      request.target,
      @mttp_core.Headers::of(request.fields),
      framing,
      request.version,
    )
    let parsed = @h1.parse_request_head(head)
    assert_eq(parsed.meth, request.meth)
    assert_eq(parsed.target, request.target)
    assert_eq(parsed.version, request.version)
    let anticipates = request.meth is (Post | Put | Patch)
    let expected = request.fields.copy()
    expected.append(framing_pairs(framing, empty_length=anticipates))
    assert_eq(parsed.headers, read_as(expected))
    // Names compare case-insensitively, in order, values exactly.
    for i, pair in parsed.headers.iter().collect() {
      assert_eq(pair.0, expected[i].0.to_lower())
      assert_eq(pair.1, expected[i].1)
    }
    let read_back = if framing == NoBody && anticipates {
      @h1.Framing::Length(0)
    } else {
      framing
    }
    assert_eq(@h1.request_framing(parsed.headers), read_back)
  })
}

///|
test "written response heads parse back to the same response" {
  let responses = gen_response()
  for_seeds(200, seed => {
    let response = responses.sample(seed~)
    let framing = if refuses_body_framing(response.status, response.meth) {
      @h1.Framing::NoBody
    } else {
      writer_framing(response.body, close=response.close)
    }
    let head = @h1.write_response_head(
      response.status,
      @mttp_core.Headers::of(response.fields),
      framing,
      response.version,
      meth=response.meth,
    )
    let parsed = @h1.parse_response_head(head)
    assert_eq(parsed.version, response.version)
    assert_eq(parsed.status, response.status)
    let no_body = never_has_body(response.status, response.meth)
    let expected = response.fields.copy()
    expected.append(framing_pairs(framing, empty_length=!no_body))
    assert_eq(parsed.headers, read_as(expected))
    let read_back : @h1.Framing = match framing {
      _ if no_body => NoBody
      NoBody => Length(0)
      framing => framing
    }
    assert_eq(
      @h1.response_framing(
        parsed.headers,
        status=response.status,
        meth=response.meth,
      ),
      read_back,
    )
  })
}

///|
/// Decodes a chunked body fed as `pieces`: the payload, the trailers and the
/// bytes after the body, or the refusal's kind.
fn decode_chunked(
  pieces : Array[Bytes],
  limits : @h1.Limits,
) -> Result[(Bytes, @mttp_core.Headers, Bytes), @h1.ParseKind] raise {
  let decoder = @h1.ChunkedDecoder::new(limits)
  let body = Buffer()
  let rest = Buffer()
  let mut trailers = @mttp_core.Headers::empty()
  try {
    for piece in pieces {
      let result = decoder.feed(piece)
      for chunk in result.chunks {
        guard !chunk.is_empty() else { fail("empty chunk emitted") }
        body.write_bytes(chunk)
      }
      rest.write_bytesview(piece[result.consumed:])
      trailers = result.trailers
    }
    decoder.finish()
    Ok((body.to_bytes(), trailers, rest.to_bytes()))
  } catch {
    @h1.ParseError(kind~, ..) => Err(kind)
    error => raise error
  }
}

///|
test "encoded chunks decode back to the payload and trailers at every split" {
  let requests = gen_request()
  let mut chunked = 0
  for_seeds(300, seed => {
    guard requests.sample(seed~).body is Chunks(chunks~, trailers~) else {
      return
    }
    chunked += 1
    let wire = Buffer()
    chunks.each(chunk => wire.write_bytes(@h1.encode_chunk(chunk)))
    if trailers.is_empty() {
      wire.write_bytes(@h1.encode_chunk(b""))
    } else {
      wire.write_bytes(b"0\r\n")
      for field in trailers {
        write_latin1(wire, "\{field.0}: \{field.1}\r\n")
      }
      wire.write_bytes(b"\r\n")
    }
    wire.write_bytes(b"NEXT")
    let decoded = check_splits(wire.to_bytes(), pieces => {
      decode_chunked(pieces, @h1.Limits::default())
    })
    assert_eq(decoded, Ok((concat(chunks), read_as(trailers), b"NEXT")))
  })
  // The generator draws chunked bodies often enough to mean something.
  assert_true(chunked > 50, msg="only \{chunked} chunked bodies")
}

///|
/// What reading a generated request must give.
fn expected_request(request : GenRequest) -> Message {
  let framing : @h1.Framing = match request.body {
    Absent => NoBody
    Sized(bytes) => Length(bytes.length().to_int64())
    Chunks(..) => Chunked
  }
  {
    head: request.head,
    framing,
    body: request.body.payload(),
    trailers: request.body.trailers(),
    rest: request.suffix,
  }
}

///|
/// What reading a generated response must give.
fn expected_response(response : GenResponse) -> Message {
  let empty = @mttp_core.Headers::empty()
  if never_has_body(response.status, response.meth) {
    return {
      head: response.head,
      framing: NoBody,
      body: b"",
      trailers: empty,
      rest: concat([response.body_wire, response.suffix]),
    }
  }
  match response.body {
    Absent =>
      {
        head: response.head,
        framing: UntilClose,
        body: response.suffix,
        trailers: empty,
        rest: b"",
      }
    Sized(bytes) =>
      {
        head: response.head,
        framing: Length(bytes.length().to_int64()),
        body: bytes,
        trailers: empty,
        rest: response.suffix,
      }
    Chunks(..) =>
      {
        head: response.head,
        framing: Chunked,
        body: response.body.payload(),
        trailers: response.body.trailers(),
        rest: response.suffix,
      }
  }
}

///|
test "generated requests read the same whole, at every split and byte by byte" {
  let requests = gen_request()
  for_seeds(60, seed => {
    let request = requests.sample(seed~)
    let message = check_splits(request.wire, pieces => read_request(pieces))
    assert_eq(message, Ok(expected_request(request)))
    let parsed = @h1.parse_request_head(request.head)
    assert_eq(parsed.meth, request.meth)
    assert_eq(parsed.target, request.target)
    assert_eq(parsed.version, request.version)
    assert_eq(parsed.headers, read_as(request.head_fields))
  })
}

///|
test "generated responses read the same whole, at every split and byte by byte" {
  let responses = gen_response()
  for_seeds(60, seed => {
    let response = responses.sample(seed~)
    let message = check_splits(response.wire, pieces => {
      read_response(pieces, meth=response.meth)
    })
    assert_eq(message, Ok(expected_response(response)))
    let parsed = @h1.parse_response_head(response.head)
    assert_eq(parsed.version, response.version)
    assert_eq(parsed.status, response.status)
    assert_eq(parsed.headers, read_as(response.head_fields))
  })
}

///|
test "damaged and arbitrary bytes end in a value or a refusal, at every split" {
  let inputs = gen_hostile()
  let draws = drawn(d => (d.limits(), d.pick(methods_answered)))
  let mut accepted = 0
  let mut refused = 0
  for_seeds(150, seed => {
    let wire = inputs.sample(seed~)
    let (limits, meth) = draws.sample(seed~)
    // check_splits compares the outcome whole, at every split and byte by
    // byte; an outcome is a message or a refusal's kind. A panic or another
    // error fails the test.
    for
      outcome in [
        check_splits(wire, pieces => read_request(pieces, limits~)),
        check_splits(wire, pieces => read_response(pieces, meth~, limits~)),
      ] {
      match outcome {
        Ok(_) => accepted += 1
        Err(_) => refused += 1
      }
    }
    // The chunked decoder alone, on bytes that are mostly not chunked.
    let _ = check_splits(wire, pieces => decode_chunked(pieces, limits))
  })
  // Both outcomes occur, so the inputs reach past the first byte.
  assert_true(accepted > 10, msg="only \{accepted} accepted")
  assert_true(refused > 100, msg="only \{refused} refused")
}

///|
/// Writes a body the way `framing` says, for reading it back; a
/// close-delimited body is the bytes up to the end of input.
fn encode_body(
  framing : @h1.Framing,
  body : Bytes,
  trailers : @mttp_core.Headers,
) -> Bytes {
  match framing {
    Length(_) | UntilClose => body
    Chunked => {
      let out = Buffer()
      if !body.is_empty() {
        out.write_bytes(@h1.encode_chunk(body))
      }
      out.write_bytes(b"0\r\n")
      for field in trailers.iter() {
        write_latin1(out, "\{field.0}: \{field.1}\r\n")
      }
      out.write_bytes(b"\r\n")
      out.to_bytes()
    }
    _ => b""
  }
}

///|
/// The head fields other than the framing ones, which a writer replaces.
fn without_framing(headers : @mttp_core.Headers) -> @mttp_core.Headers {
  headers.remove("content-length").remove("transfer-encoding")
}

///|
/// A request the reader accepts, written back by the writer, reads again
/// with the same method, target, version, fields, framing and body.
fn rewrite_request(wire : Bytes) -> Bool raise {
  guard read_request([wire]) is Ok(message) else { return false }
  let parsed = @h1.parse_request_head(message.head)
  let written = @h1.write_request_head(
    parsed.meth,
    parsed.target,
    parsed.headers,
    message.framing,
    parsed.version,
  )
  let again = read_request([
    written,
    encode_body(message.framing, message.body, message.trailers),
  ])
  guard again is Ok(again) else {
    fail("written request refused: \{Repr(again)}")
  }
  let reparsed = @h1.parse_request_head(again.head)
  assert_eq(reparsed.meth, parsed.meth)
  assert_eq(reparsed.target, parsed.target)
  assert_eq(reparsed.version, parsed.version)
  assert_eq(without_framing(reparsed.headers), without_framing(parsed.headers))
  let framing = if message.framing == NoBody &&
    parsed.meth is (Post | Put | Patch) {
    @h1.Framing::Length(0)
  } else {
    message.framing
  }
  assert_eq(again.framing, framing)
  assert_eq(again.body, message.body)
  assert_eq(again.trailers, message.trailers)
  assert_eq(again.rest, b"")
  true
}

///|
/// A response the reader accepts, written back by the writer, reads again
/// with the same version, status, fields, framing and body.
fn rewrite_response(wire : Bytes, meth : @mttp_core.Method) -> Bool raise {
  guard read_response([wire], meth~) is Ok(message) else { return false }
  let parsed = @h1.parse_response_head(message.head)
  let written = @h1.write_response_head(
    parsed.status,
    parsed.headers,
    message.framing,
    parsed.version,
    meth~,
  )
  let again = read_response(
    [written, encode_body(message.framing, message.body, message.trailers)],
    meth~,
  )
  guard again is Ok(again) else {
    fail("written response refused: \{Repr(again)}")
  }
  let reparsed = @h1.parse_response_head(again.head)
  assert_eq(reparsed.version, parsed.version)
  assert_eq(reparsed.status, parsed.status)
  // A close-delimited response is written with `Connection: close`.
  let fields = if message.framing == UntilClose {
    without_framing(parsed.headers).set("connection", "close")
  } else {
    without_framing(parsed.headers)
  }
  assert_eq(without_framing(reparsed.headers), fields)
  assert_eq(again.framing, message.framing)
  assert_eq(again.body, message.body)
  assert_eq(again.trailers, message.trailers)
  true
}

///|
test "what the reader accepts, the writer writes back and the reader reads again" {
  let requests = gen_request()
  let responses = gen_response()
  let inputs = gen_hostile()
  let meths = drawn(d => d.pick(methods_answered))
  let mut accepted = 0
  for_seeds(150, seed => {
    let response = responses.sample(seed~)
    let hostile = inputs.sample(seed~)
    let meth = meths.sample(seed~)
    for
      ok in [
        rewrite_request(requests.sample(seed~).wire),
        rewrite_response(response.wire, response.meth),
        rewrite_request(hostile),
        rewrite_response(hostile, meth),
      ] {
      if ok {
        accepted += 1
      }
    }
  })
  assert_true(accepted > 300, msg="only \{accepted} accepted")
}
