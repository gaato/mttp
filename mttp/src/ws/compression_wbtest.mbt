///|
fn parsed(text : String) -> Array[@handshake.Extension] raise {
  @handshake.parse_extensions(text)
}

///|
test "RFC 7692 parameters reject duplicates unknowns valued flags and noncanonical windows" {
  let options = Compression::new()
  for name in ["server_max_window_bits", "client_max_window_bits"] {
    for
      value in [
        "0", "7", "16", "015", "8.0", "-8", "+15", "", " 15", "15 ", "fifteen",
      ] {
      let extension : @handshake.Extension = {
        name: "permessage-deflate",
        params: [{ name, value: Some(value), }],
      }
      assert_true(options.accept([extension]) is None)
      assert_true(deflate_params(extension, response=true) is None)
    }
  }
  for
    param in [
      "unknown", "Server_no_context_takeover", "server_no_context_takeover=1", "client_no_context_takeover=0",
      "server_max_window_bits", "server_max_window_bits=07", "client_max_window_bits=08",
      "client_max_window_bits=16", "server_max_window_bits=7", "server_max_window_bits=+15",
      "client_max_window_bits=\"\"",
    ] {
    let elements = parsed("permessage-deflate; " + param)
    assert_true(options.accept(elements) is None, msg=param)
    try options.validate(elements) catch {
      @core_ws.WsError(kind=Handshake(status=101), ..) => ()
      _ => fail(param)
    } noraise {
      _ => fail(param)
    }
  }
  for
    param in [
      "server_no_context_takeover", "client_no_context_takeover", "server_max_window_bits=15",
      "client_max_window_bits=15",
    ] {
    let elements = parsed("permessage-deflate; " + param + "; " + param)
    assert_true(options.accept(elements) is None)
    try options.validate(elements) catch {
      _ => ()
    } noraise {
      _ => fail("duplicate accepted")
    }
  }
}

///|
test "RFC 7692 server window constraints client hints fallback offers and bare client window" {
  let options = Compression::new(
    server_no_context_takeover=false,
    client_no_context_takeover=false,
  )
  for bits in 8..<=15 {
    let offers = parsed("permessage-deflate; server_max_window_bits=\{bits}")
    assert_eq(options.accept(offers) is Some(_), bits == 15)
    let (response, _) = options
      .accept(parsed("permessage-deflate; client_max_window_bits=\{bits}"))
      .unwrap()
    assert_eq(@handshake.print_extensions([response]), "permessage-deflate")
    let decoded = options.validate(
      parsed("permessage-deflate; server_max_window_bits=\{bits}"),
    )
    assert_true(decoded is Some(_))
    let response = parsed("permessage-deflate; client_max_window_bits=\{bits}")
    let ok = try {
      ignore(options.validate(response))
      true
    } catch {
      _ => false
    }
    assert_eq(ok, bits == 15)
  }
  assert_true(
    options.accept(parsed("permessage-deflate; client_max_window_bits"))
    is Some(_),
  )
  try
    options.validate(parsed("permessage-deflate; client_max_window_bits"))
  catch {
    _ => ()
  } noraise {
    _ => fail("bare response window")
  }
  let fallback = parsed(
    "unknown, permessage-deflate; server_max_window_bits=8, permessage-deflate",
  )
  assert_true(options.accept(fallback) is Some(_))
  assert_true(options.accept(parsed("unknown")) is None)
  assert_true(options.validate([]) is None)
  for response in ["unknown", "permessage-deflate, permessage-deflate"] {
    try options.validate(parsed(response)) catch {
      _ => ()
    } noraise {
      _ => fail(response)
    }
  }
}

///|
test "context flags are required requests optional hints and allowed unsolicited response flags" {
  let defaults = Compression::new()
  assert_eq(
    defaults.offer(),
    "permessage-deflate; client_max_window_bits; server_no_context_takeover; client_no_context_takeover",
  )
  let takeover = Compression::new(
    server_no_context_takeover=false,
    client_no_context_takeover=false,
  )
  assert_eq(takeover.offer(), "permessage-deflate; client_max_window_bits")
  let (selected, _) = defaults.accept(parsed("permessage-deflate")).unwrap()
  assert_eq(
    @handshake.print_extensions([selected]),
    "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
  )
  let (selected, _) = takeover.accept(parsed(defaults.offer())).unwrap()
  assert_eq(
    @handshake.print_extensions([selected]),
    "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
  )
  assert_true(takeover.validate([selected]) is Some(_))
  try defaults.validate(parsed("permessage-deflate")) catch {
    _ => ()
  } noraise {
    _ => fail("server constraint ignored")
  }
  assert_true(
    defaults.validate(parsed("permessage-deflate; server_no_context_takeover"))
    is Some(_),
  )
  let (quoted, _) = takeover
    .accept(
      parsed(
        "permessage-deflate; server_max_window_bits=\"15\"; client_max_window_bits=\"8\"",
      ),
    )
    .unwrap()
  assert_eq(
    @handshake.print_extensions([quoted]),
    "permessage-deflate; server_max_window_bits=15",
  )
}

///|
test "takeover reuses history while no takeover repeats independent encodings" {
  for reset in [false, true] {
    let concrete = PerMessageDeflate::new(
      encode_reset=reset,
      decode_reset=reset,
    )
    let encoder : &@core_ws.Extension = concrete
    let decoder = PerMessageDeflate::new(encode_reset=reset, decode_reset=reset)
    let extension : &@core_ws.Extension = decoder
    let raw = Bytes::makei(32769, i => (i % 251).to_byte())
    let memory = concrete.encoder.memory_usage()
    let (first, _) = encoder.encode(raw)
    assert_eq(extension.decode(first, rsv1=true, max_bytes=raw.length()), raw)
    assert_eq(decoder.history.length(), if reset { 0 } else { 32768 })
    // Uncompressed messages do not replace the compression dictionary.
    assert_eq(
      extension.decode(b"uncompressed", rsv1=false, max_bytes=12),
      b"uncompressed",
    )
    let (second, _) = encoder.encode(raw)
    assert_eq(extension.decode(second, rsv1=true, max_bytes=raw.length()), raw)
    assert_eq(concrete.encoder.memory_usage(), memory)
    if reset {
      assert_eq(first, second)
    } else {
      assert_true(second.length() < first.length())
    }
  }
}

///|
test "RFC 7692 hello vector tail removal empty messages and context takeover round trips" {
  for reset in [true, false] {
    let encoder : &@core_ws.Extension = PerMessageDeflate::new(
      encode_reset=reset,
      decode_reset=reset,
    )
    let decoder : &@core_ws.Extension = PerMessageDeflate::new(
      encode_reset=reset,
      decode_reset=reset,
    )
    assert_eq(encoder.name(), "permessage-deflate")
    assert_eq(
      decoder.decode(b"\xf2\x48\xcd\xc9\xc9\x07\x00", rsv1=true, max_bytes=5),
      b"Hello",
    )
    for
      input in [
        b"",
        b"",
        b"Hello",
        b"Hello",
        Bytes::makei(100000, i => (i % 251).to_byte()),
        b"Hello",
        b"",
      ] {
      let (wire, rsv1) = encoder.encode(input)
      assert_true(rsv1)
      assert_eq(decoder.decode(wire, rsv1~, max_bytes=input.length()), input)
    }
    assert_eq(decoder.decode(b"plain", rsv1=false, max_bytes=5), b"plain")
  }
}

///|
test "inflated output accepts exact bound rejects plus one while inflating and retains only 32 KiB history" {
  let encoder : &@core_ws.Extension = PerMessageDeflate::new(
    encode_reset=false,
    decode_reset=false,
  )
  let decoder = PerMessageDeflate::new(encode_reset=false, decode_reset=false)
  let extension : &@core_ws.Extension = decoder
  for size in [0, 1, 8192, 32768, 100000] {
    let previous = decoder.history.length()
    let raw = Bytes::make(size, b'x')
    let (wire, _) = encoder.encode(raw)
    assert_eq(extension.decode(wire, rsv1=true, max_bytes=size), raw)
    assert_eq(decoder.history.length(), (size + previous).min(32768))
    if size > 0 {
      let fresh : &@core_ws.Extension = PerMessageDeflate::new(
        encode_reset=true,
        decode_reset=true,
      )
      let encoder : &@core_ws.Extension = PerMessageDeflate::new(
        encode_reset=true,
        decode_reset=true,
      )
      let (wire, _) = encoder.encode(raw)
      try fresh.decode(wire, rsv1=true, max_bytes=size - 1) catch {
        @core_ws.WsError(kind=TooLarge(limit~), ..) =>
          assert_eq(limit, size - 1)
        _ => fail("wrong overflow")
      } noraise {
        _ => fail("overflow accepted")
      }
    }
  }
  assert_eq(decoder.history.length(), 32768)
  for (wire, rsv1, limit) in [(b"plain", false, 4), (b"", true, -1)] {
    try extension.decode(wire, rsv1~, max_bytes=limit) catch {
      @core_ws.WsError(kind=TooLarge(_), ..) => ()
      _ => fail("wrong limit error")
    } noraise {
      _ => fail("limit ignored")
    }
  }
}

///|
test "malformed and truncated deflate fail and BFINAL blocks preserve the dictionary" {
  for wire in [b"\x07", b"\xf2\x48\xcd", b"", b"\x00\x01\x00\x00\x00"] {
    let decoder : &@core_ws.Extension = PerMessageDeflate::new(
      encode_reset=true,
      decode_reset=true,
    )
    try decoder.decode(wire, rsv1=true, max_bytes=100) catch {
      @core_ws.WsError(kind=Protocol, ..) => ()
      _ => fail("wrong malformed error")
    } noraise {
      _ => fail("malformed accepted")
    }
  }
  let decoder : &@core_ws.Extension = PerMessageDeflate::new(
    encode_reset=false,
    decode_reset=false,
  )
  // RFC 7692 section 7.2.3.4: final fixed block, padding, empty stored header.
  assert_eq(
    decoder.decode(b"\xf3\x48\xcd\xc9\xc9\x07\x00\x00", rsv1=true, max_bytes=5),
    b"Hello",
  )
  let reference = @deflate.compress(b"Hello", dictionary=b"Hello")
  assert_eq(
    decoder.decode(reference + b"\x00", rsv1=true, max_bytes=5),
    b"Hello",
  )
  let members = @deflate.compress(b"Hello") + reference + b"\x00"
  assert_eq(decoder.decode(members, rsv1=true, max_bytes=10), b"HelloHello")
  // reset() to this message's original Hello dictionary would silently
  // turn the second World into Hello. BFINAL must preserve the updated window.
  let world = @deflate.compress(b"World", dictionary=b"World")
  assert_true(world.length() < @deflate.compress(b"World").length())
  let members = @deflate.compress(b"World") + world + b"\x00"
  assert_eq(decoder.decode(members, rsv1=true, max_bytes=10), b"WorldWorld")
  for reset in [true, false] {
    let reader : &@core_ws.Extension = PerMessageDeflate::new(
      encode_reset=reset,
      decode_reset=reset,
    )
    assert_eq(
      reader.decode(
        @deflate.compress(b"Hello") + b"\x00",
        rsv1=true,
        max_bytes=5,
      ),
      b"Hello",
    )
    // No-context-takeover resets between messages, never between BFINAL
    // members within the same message (RFC 7692 section 7.2).
    assert_eq(reader.decode(members, rsv1=true, max_bytes=10), b"WorldWorld")
  }
}
