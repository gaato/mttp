///|
test "combined readers buffer once and select each interpretation once" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"a=", b"1&a=2"])
  let selections = Ref(0)
  let reader = @client.as_both(
    @client.from_head(_ => {
      selections.val += 1
      @client.as_string()
    }),
    @client.from_head(_ => {
      selections.val += 1
      @client.as_form()
    }),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.FakeClock::new(),
  )
  let reply = d.run(() => {
    client.send(@client.request(@model.Request::get("/form")).response(reader))
  })
  assert_eq(reply.body, ("a=1&a=2", [("a", "1"), ("a", "2")]))
  assert_eq(selections.val, 2)
  assert_eq(source.closes(), 1)
  assert_eq(source.reads(), 3)
}

///|
suberror ChosenReject {
  ChosenReject(Int32)
}

///|
test "combined readers honor each head rejection and left error priority" {
  for accept_left in [false, true] {
    let reader = @client.as_both(
      @client.ResponseAs::new((_, _, _) => 1, accept_head=_ => accept_left, reject=(
        _,
        _,
      ) => raise ChosenReject(1)),
      @client.ResponseAs::new((_, _, _) => 2, accept_head=_ => false, reject=(
        _,
        _,
      ) => raise ChosenReject(2)),
    )
    let client = @client.Client::new(
      @client.from_fn((_, _) => @model.Response::new(400)),
      @fake.FakeClock::new(),
    )
    try
      @driver.run_sync(() => {
        client.send(@client.request(@model.Request::get("/")).response(reader))
      })
    catch {
      ChosenReject(which) => assert_eq(which, if accept_left { 2 } else { 1 })
      _ => fail("wrong rejection")
    } noraise {
      _ => fail("expected rejection")
    }
  }
}

///|
fn lines(chunks : Array[Bytes], limit~ : Int32 = 100) -> Array[String] raise {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, chunks)
  let values = []
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.FakeClock::new(),
  )
  let _ = d.run(() => {
    client.send(
      @client.request(@model.Request::get("/")).response(
        @client.as_lines(value => values.push(value), max_line_bytes=limit),
      ),
    )
  })
  assert_eq(source.closes(), 1)
  values
}

///|
test "line reader handles every byte split including UTF-8 and CRLF boundaries" {
  let bytes = @model.encode_utf8("a\r\n\n日本\nlast\r")
  for cut in 0..<=bytes.length() {
    assert_eq(lines([bytes[:cut].to_owned(), bytes[cut:].to_owned()]), [
      "a", "", "日本", "last\r",
    ])
  }
  assert_eq(
    lines(Array::makei(bytes.length(), i => bytes[i:i + 1].to_owned())),
    ["a", "", "日本", "last\r"],
  )
  assert_eq(lines([]), [])
  assert_eq(lines([b"x\r\ry\n\xff"]), ["x\r\ry", "�"])
  assert_eq(lines([b"\r\n\n"], limit=0), ["", ""])
  assert_eq(lines([b"123\r", b"\n"], limit=3), ["123"])
}

///|
test "line bounds refuse crossing bytes close streams and default to one MiB" {
  assert_eq(lines([b"123"], limit=3), ["123"])
  for bytes in [b"1234", b"123\r", b"123\rx"] {
    try lines([bytes], limit=3) catch {
      @model.TransportError(kind=TooLarge(limit=3), ..) => ()
      _ => fail("wrong overflow error")
    } noraise {
      _ => fail("accepted oversized line")
    }
  }
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [Bytes::make(1024 * 1024, b'x'), b"x"])
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.FakeClock::new(),
  )
  try
    d.run(() => {
      client.send(
        @client.request(@model.Request::get("/")).response(
          @client.as_lines(_ => ()),
        ),
      )
    })
  catch {
    @model.TransportError(kind=TooLarge(limit=1048576), ..) => ()
    _ => fail("wrong default limit")
  } noraise {
    _ => fail("accepted default overflow")
  }
  assert_eq(source.closes(), 1)
  try lines([], limit=-1) catch {
    @model.TransportError(kind=Invalid, ..) => ()
    _ => fail("wrong negative bound error")
  } noraise {
    _ => fail("accepted negative limit")
  }
}

///|
test "streaming line callback errors close once without retrying delivered lines" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"one\ntwo\n"])
  let calls = Ref(0)
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.FakeClock::new(),
    retry=@client.RetryPolicy::default(),
  )
  try
    d.run(() => {
      client.send(
        @client.request(@model.Request::get("/")).response(
          @client.as_lines(_ => {
            raise @model.TransportError(
              kind=Network,
              phase=Body,
              detail="callback",
            )
          }),
        ),
      )
    })
  catch {
    @model.TransportError(kind=Network, ..) => ()
    _ => fail("wrong callback error")
  } noraise {
    _ => fail("expected callback error")
  }
  assert_eq(calls.val, 1)
  assert_eq(source.closes(), 1)
}
