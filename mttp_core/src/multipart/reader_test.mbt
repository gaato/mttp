///|
async fn received(chunks : Array[Bytes]) -> Array[@multipart.Part] {
  let source = parts_of(chunks)
  let reader = @multipart.MultipartReader::new(source, "B")
  let output = []
  while reader.next_part() is Some(part) {
    let body = Buffer()
    while part.body.read_some() is Some(bytes) {
      body.write_bytes(bytes)
    }
    output.push(@multipart.Part::{
      name: part.head.name,
      filename: part.head.filename,
      content_type: part.head.content_type,
      body: Bytes(body.to_bytes()),
    })
  }
  assert_true(source.closed)
  output
}

///|
test "quoted MIME parameters allow trailing spaces and tabs before another parameter" {
  assert_eq(
    @multipart.parse_boundary(
      "multipart/form-data; boundary=\"B\" \t; extra=ok",
    ),
    "B",
  )
  let parts = @multipart.parse(
    b"--B\r\nContent-Disposition: form-data; name=\"field\" \t; filename=\"file.txt\" \t\r\n\r\nx\r\n--B--\r\n",
    "B",
  )
  assert_eq(parts.length(), 1)
  assert_eq(parts[0].name, "field")
  assert_eq(parts[0].filename, Some("file.txt"))
  assert_eq(parts[0].body.as_bytes(), Some(b"x"))
}

///|
test "reader corpus at every split and byte by byte" {
  let corpus : Array[(Bytes, Bool)] = [
    (
      b"--B\r\nContent-Disposition: form-data;\r\n\tname=\"x\"\r\n\r\ndata\r\n--B--\r\n",
      true,
    ),
    (b"--B-- \t", true),
    (
      b"--B\r\nContent-Disposition: form-data; name = \"x\" \r\n\r\na\nb\rc\r\n--B--\r\n",
      true,
    ),
    (b"--B--\r\n", true),
    (
      b"preamble\r\n--B \t\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n\r\n--B\t\r\nContent-Disposition: form-data; name=x\r\n\r\na--B\r\n--Bx\r\n--B-- \t\r\nepilogue",
      true,
    ),
    (b"--B\r\nContent-Disposition: form-data; name=x\r\n\r\na\r\n--B--", true),
    (b"--B\r\nContent-Disposition: form-data; name=x\r\n\r\na", false),
    (b"--B\nContent-Disposition: form-data; name=x\n\na\n--B--\n", false),
    (
      b"--B\r\nContent-Disposition: form-data; name=x\n\r\na\r\n--B--\r\n", false,
    ),
    (
      b"--B\r\nContent-Disposition: form-data; name=x; filename*=UTF-8''a\r\n\r\na\r\n--B--\r\n",
      false,
    ),
    (
      b"--B\r\nContent-Disposition: form-data; name=x; filename=\"a\\\"b\"\r\nContent-Type: application/octet-stream\r\n\r\n\x00\xff\r\n--B--\r\n",
      true,
    ),
  ]
  for (bytes, valid) in corpus {
    let expected = Some(@multipart.parse(bytes, "B")) catch {
      @mttp_core.TransportError(kind=Protocol, phase=Body, ..) => None
      error => raise error
    }
    assert_eq(expected is Some(_), valid)
    let check = fn(chunks : Array[Bytes]) raise {
      let d = @driver.Driver::new()
      let result = Some(d.run(() => received(chunks))) catch {
        @mttp_core.TransportError(kind=Protocol, phase=Body, ..) => None
        error => raise error
      }
      assert_eq(result, expected)
    }
    for split in 0..<=bytes.length() {
      check([bytes[:split].to_owned(), bytes[split:].to_owned()])
    }
    check(bytes.iter().map(b => Bytes::from_array([b])).collect())
  }
}

///|
test "reader skips unread parts and invalidates older streams" {
  let (_, bytes) = @multipart.encode(
    [
      @multipart.Part::text("same", "first"),
      @multipart.Part::text("same", ""),
      @multipart.Part::text("last", "third"),
    ],
    "B",
  )
  let source = parts_of([bytes])
  let reader = @multipart.MultipartReader::new(source, "B")
  @driver.Driver::new().run(() => {
    let first = reader.next_part().unwrap()
    assert_eq(first.head.name, "same")
    first.body.close()
    let empty = reader.next_part().unwrap()
    assert_eq(first.body.read_some(), None)
    assert_eq(empty.body.read_some(), None)
    let last = reader.next_part().unwrap()
    assert_eq(last.body.read_some(), Some(b"third"))
    assert_eq(last.body.read_some(), None)
    assert_true(reader.next_part() is None)
    reader.close()
    assert_true(reader.next_part() is None)
  })
  assert_true(source.closed)
}

///|
fn overflow(run : () -> Unit raise, limit : Int32) -> Unit raise {
  try run() catch {
    @mttp_core.TransportError(kind=TooLarge(limit=actual), phase=Body, ..) =>
      assert_eq(actual, limit)
    error => raise error
  } noraise {
    _ => fail("bound not enforced")
  }
}

///|
test "multipart exceeds every configured resource bound" {
  assert_eq(
    @multipart.parse_boundary("Multipart/Form-Data; boundary=\"a b\""),
    "a b",
  )
  for
    content_type in [
      "text/plain; boundary=B", "multipart/form-data", "multipart/form-data; boundary=\"\"",
      "multipart/form-data; boundary=bad=token",
    ] {
    try @multipart.parse_boundary(content_type) |> ignore catch {
      @mttp_core.TransportError(kind=Protocol, ..) => ()
      error => raise error
    } noraise {
      _ => fail("invalid content type accepted")
    }
  }
  for
    run in [
      () => ignore(@multipart.parse(b"", "B", max_part_bytes=-1)),
      () => ignore(@multipart.parse(b"", "B", max_parts=-1)),
    ] {
    try run() catch {
      @mttp_core.TransportError(kind=Protocol, ..) => ()
      error => raise error
    } noraise {
      _ => fail("invalid limits accepted")
    }
  }
  assert_eq(@multipart.parse(b"--B--\r\n", "B", max_parts=0).length(), 0)
  let (_, largest_boundary) = @multipart.encode(
    [@multipart.Part::text("x", "")],
    "B".repeat(70),
  )
  assert_eq(
    @multipart.parse(largest_boundary, "B".repeat(70), max_buffer_bytes=78).length(),
    1,
  )
  let (_, bytes) = @multipart.encode([@multipart.Part::text("a", "abcd")], "B")
  assert_eq(
    @multipart.parse(
      bytes,
      "B",
      max_parts=1,
      max_total_bytes=bytes.length(),
      max_part_bytes=4,
    ).length(),
    1,
  )
  overflow(() => ignore(@multipart.parse(bytes, "B", max_parts=0)), 0)
  overflow(() => ignore(@multipart.parse(bytes, "B", max_header_bytes=8)), 8)
  overflow(
    () => {
      ignore(@multipart.parse(bytes, "B", max_total_bytes=bytes.length() - 1))
    },
    bytes.length() - 1,
  )
  overflow(() => ignore(@multipart.parse(bytes, "B", max_part_bytes=3)), 3)
  let padding = b"--B" + Bytes::make(79, b' ') + b"\r\n"
  overflow(
    () => ignore(@multipart.parse(padding, "B", max_buffer_bytes=78)),
    78,
  )
  let source = parts_of([bytes])
  let reader = @multipart.MultipartReader::new(source, "B", max_total_bytes=8)
  overflow(() => @driver.Driver::new().run(() => ignore(reader.next_part())), 8)
  assert_true(source.closed)
}

///|
test "encoder reader round trip property over arbitrary binary parts" {
  let random = @random.Rand::chacha8(seed=Bytes::make(32, 42))
  for _ in 0..<100 {
    let parts : Array[@multipart.Part] = []
    for index in 0..<random.int(limit=6) {
      let bytes = Bytes::from_array(
        Array::makei(random.int(limit=100), _ => random.int(limit=256).to_byte()),
      )
      parts.push(
        @multipart.Part::file(
          "field\{index}",
          "file\{index}",
          "application/octet-stream",
          bytes,
        ),
      )
    }
    let (_, bytes) = @multipart.encode(parts, "B")
    assert_eq(@multipart.parse(bytes, "B"), parts)
    assert_eq(@driver.Driver::new().run(() => received([bytes])), parts)
  }
}

///|
test "reader closes before first pull on malformed input and on source failure" {
  let d = @driver.Driver::new()
  let failed = @sim.Feed::new(d, [
    Fail(
      @mttp_core.TransportError(kind=Network, phase=Body, detail="peer failed"),
    ),
  ])
  let reader = @multipart.MultipartReader::new(failed, "B")
  try d.run(() => ignore(reader.next_part())) catch {
    @mttp_core.TransportError(kind=Network, detail="peer failed", ..) => ()
    error => raise error
  } noraise {
    _ => fail("source failure lost")
  }
  assert_eq(failed.closes(), 1)
  for in_body in [false, true] {
    let d = @driver.Driver::new()
    let source = @sim.Feed::new(
      d,
      if in_body {
        [
          Chunk(b"--B\r\nContent-Disposition: form-data; name=x\r\n\r\n"),
          Wait(100000),
          End,
        ]
      } else {
        [Wait(100000), End]
      },
    )
    let reader = @multipart.MultipartReader::new(source, "B")
    d.run(() => {
      let task = d.spawn(() => {
        if in_body {
          ignore(reader.next_part().unwrap().body.read_some())
        } else {
          ignore(reader.next_part())
        }
      })
      d.pause()
      task.cancel()
      assert_false(task.wait())
      assert_true(reader.next_part() is None)
    })
    assert_eq(source.closes(), 1)
    assert_eq(source.cancellations(), 1)
  }
  let source = parts_of([])
  try @multipart.MultipartReader::new(source, "") |> ignore catch {
    @mttp_core.TransportError(kind=Protocol, ..) => ()
    error => raise error
  } noraise {
    _ => fail("invalid boundary accepted")
  }
  assert_true(source.closed)
  let source = parts_of([])
  let reader = @multipart.MultipartReader::new(source, "B")
  reader.close()
  assert_true(source.closed)
  assert_true(@driver.Driver::new().run(() => reader.next_part()) is None)
  let malformed : Array[Bytes] = [
    b"--B\r\n Content-Disposition: form-data; name=x\r\n\r\nx\r\n--B--\r\n", b"--B\r\nContent-Disposition: form-data; name=x\ninvalid\r\n\r\nx\r\n--B--\r\n",
    b"--B\r\nContent-Disposition: form-data; =x\r\n\r\nx\r\n--B--\r\n", b"--B\r\nContent-Disposition: form-data; name=\"x\\\r\n\r\nx\r\n--B--\r\n",
    b"--B\r\nBad\r\n\r\nx\r\n--B--\r\n", b"--B\r\nContent-Disposition: attachment; name=x\r\n\r\nx\r\n--B--\r\n",
    b"--B\r\nContent-Disposition: form-data; filename=x\r\n\r\nx\r\n--B--\r\n", b"--B\r\nContent-Disposition: form-data; name=x; name=y\r\n\r\nx\r\n--B--\r\n",
    b"--B\r\nContent-Disposition: form-data; name=\"x\r\n\r\nx\r\n--B--\r\n", b"--B\r\nContent-Disposition: form-data; name=\"x\"z\r\n\r\nx\r\n--B--\r\n",
    b"--B\r\nContent-Disposition: form-data; bad\r\n\r\nx\r\n--B--\r\n", b"--B\r\nContent-Disposition: form-data; name=x\r\nContent-Type: a\r\nContent-Type: b\r\n\r\nx\r\n--B--\r\n",
  ]
  for bytes in malformed {
    let source = parts_of([bytes])
    let reader = @multipart.MultipartReader::new(source, "B")
    try @driver.Driver::new().run(() => ignore(reader.next_part())) catch {
      @mttp_core.TransportError(kind=Protocol, phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("malformed headers accepted")
    }
    assert_true(source.closed)
  }
}
