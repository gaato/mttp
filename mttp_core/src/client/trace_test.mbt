///|
/// Whether `value` is a version-00 traceparent the W3C format allows:
/// lowercase hex fields of 2, 32, 16 and 2 digits, ids not all zeros.
fn w3c_traceparent(value : String) -> Bool {
  let parts = value.split("-").map(p => p.to_owned()).to_array()
  let hex = (text : String, n : Int32) => {
    text.length() == n && text.iter().all(c => c is ('0'..<='9' | 'a'..<='f'))
  }
  parts is [version, id, parent, flags] &&
  version == "00" &&
  hex(id, 32) &&
  hex(parent, 16) &&
  hex(flags, 2) &&
  !id.iter().all(c => c == '0') &&
  !parent.iter().all(c => c == '0')
}

///|
/// A backend that echoes the request headers and marks its response.
fn echo(marker : @mttp_core.AttributeKey[Int32]) -> &@mttp_core.Backend {
  @client.from_fn((request, _) => {
    ..@mttp_core.Response::new(200, headers=request.headers),
    attributes: @mttp_core.Attributes::empty().put(marker, 7),
  })
}

///|
test "trace_context adds a W3C traceparent from the injected source and records its trace id" {
  let marker : @mttp_core.AttributeKey[Int32] = @mttp_core.AttributeKey::new(
    "marker",
  )
  let samples = [0.0, 0.25, 0.999999, 0.5, 0.0625, 0.75]
  let next = Ref(0)
  let backend = @client.trace_context(echo(marker), generate=() => {
    let sample = samples[next.val % samples.length()]
    next.val += 1
    sample
  })
  @driver.run_sync(() => {
    let response = backend.send(
      @mttp_core.Request::get("https://example.test/"),
      @mttp_core.SendOptions::default(),
    )
    let value = response.headers.get("traceparent").unwrap()
    assert_eq(value, "00-0000000040000000ffffef3980000000-10000000c0000000-01")
    assert_true(w3c_traceparent(value))
    assert_eq(
      response.attributes.get(@client.trace_id),
      Some("0000000040000000ffffef3980000000"),
    )
    // Attributes the backend set pass through.
    assert_eq(response.attributes.get(marker), Some(7))
    // A source of zeros still yields valid, nonzero ids.
    let zeros = @client.trace_context(echo(marker), generate=() => 0.0)
    let value = zeros.send(
        @mttp_core.Request::get("https://example.test/"),
        @mttp_core.SendOptions::default(),
      ).headers
      .get("traceparent")
      .unwrap()
    assert_eq(value, "00-00000000000000000000000000000001-0000000000000001-01")
    assert_true(w3c_traceparent(value))
  })
}

///|
test "trace_context keeps the caller's traceparent and records only a valid one" {
  let marker : @mttp_core.AttributeKey[Int32] = @mttp_core.AttributeKey::new(
    "marker",
  )
  let calls = Ref(0)
  let backend = @client.trace_context(echo(marker), generate=() => {
    calls.val += 1
    0.5
  })
  let valid = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  let rows : Array[(String, String?)] = [
    (valid, Some("4bf92f3577b34da6a3ce929d0e0e4736")),
    // A later version may append fields.
    (
      "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra",
      Some("4bf92f3577b34da6a3ce929d0e0e4736"),
    ),
    ("00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01", None),
    ("00-00000000000000000000000000000000-00f067aa0ba902b7-01", None),
    ("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", None),
    ("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", None),
    ("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra", None),
    ("garbage", None),
  ]
  @driver.run_sync(() => {
    for row in rows {
      let (header, expected) = row
      let response = backend.send(
        @mttp_core.Request::get("https://example.test/").header(
          "traceparent", header,
        ),
        @mttp_core.SendOptions::default(),
      )
      assert_eq(response.headers.get_all("traceparent"), [header])
      assert_eq(response.attributes.get(@client.trace_id), expected)
      assert_eq(response.attributes.get(marker), Some(7))
    }
  })
  assert_eq(calls.val, 0)
}

///|
test "trace_context keeps the Backend contract" {
  @driver.run_sync(() => {
    @sim.check_backend_contract(
      () => {
        @client.trace_context(
          @client.from_fn((_, _) => @mttp_core.Response::new(200)),
          generate=() => 0.5,
        )
      },
      wrap=inner => @client.trace_context(inner, generate=() => 0.5),
    )
  })
}

///|
test "trace_context clamps a source outside [0, 1) and leaves repeated traceparent fields alone" {
  let marker : @mttp_core.AttributeKey[Int32] = @mttp_core.AttributeKey::new(
    "marker",
  )
  let samples = [-1.0, 2.0, 0.0 / 0.0, 0.5, -0.5, 1.0]
  let next = Ref(0)
  let backend = @client.trace_context(echo(marker), generate=() => {
    let sample = samples[next.val % samples.length()]
    next.val += 1
    sample
  })
  @driver.run_sync(() => {
    let value = backend.send(
        @mttp_core.Request::get("https://example.test/"),
        @mttp_core.SendOptions::default(),
      ).headers
      .get("traceparent")
      .unwrap()
    assert_eq(value, "00-00000000ffffffff0000000080000000-00000000ffffffff-01")
    assert_true(w3c_traceparent(value))
    let twice = @mttp_core.Request::get("https://example.test/")
      .header(
        "traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      )
      .header(
        "traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      )
    let response = backend.send(twice, @mttp_core.SendOptions::default())
    assert_eq(response.headers.get_all("traceparent").length(), 2)
    assert_eq(response.attributes.get(@client.trace_id), None)
  })
}
