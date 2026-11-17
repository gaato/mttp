///|
test "decimal and hex mapping cover every UTF16 code unit with only ASCII digits" {
  let alphabet = "0123456789abcdefABCDEF"
  let values : FixedArray[Int64] = [
    0L, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L, 12L, 13L, 14L, 15L, 10L, 11L,
    12L, 13L, 14L, 15L,
  ]
  for hex in [false, true] {
    let expected = FixedArray::make(65536, -1L)
    let count = if hex { alphabet.length() } else { 10 }
    for i in 0..<count {
      expected[alphabet[i].to_int()] = values[i]
    }
    for code in 0..<65536 {
      let unit = code.to_int64().to_uint16()
      assert_eq(unit.to_int(), code)
      assert_eq(digit_value(unit.to_int(), hex~), expected[code])
    }
  }
  let suffix = ";name=" + "x".repeat(4096)
  let (hex_digits, hex_n) = number_prefix("0aF" + suffix, hex=true)
  assert_eq(hex_n, 3)
  assert_eq(hex_digits, [0L, 10L, 15L])
  let (decimal_digits, decimal_n) = number_prefix("0aF" + suffix, hex=false)
  assert_eq(decimal_n, 1)
  assert_eq(decimal_digits, [0L])
  let (empty_digits, empty_n) = number_prefix(suffix, hex=true)
  assert_eq(empty_n, 0)
  assert_eq(empty_digits.length(), 0)
}

///|
test "public Content-Length agrees with the digit core including the exact bound" {
  let cases : Array[(String, Int64?)] = [
    ("", None),
    (" \t", None),
    ("0", Some(0L)),
    ("000", Some(0L)),
    (" \t00042\t ", Some(42L)),
    ("9223372036854775807", Some(9223372036854775807L)),
    ("0009223372036854775807", Some(9223372036854775807L)),
    ("9223372036854775808", None),
    ("999999999999999999999999999999", None),
    ("+1", None),
    ("-1", None),
    ("1, 1", None),
    ("1 2", None),
    ("１２", None),
    ("١٢", None),
    ("1😀", None),
    ("\r1", None),
    ("1\n", None),
  ]
  for (text, expected) in cases {
    let value = ows(text)
    let (digits, n) = number_prefix(value, hex=false)
    assert_eq(digits.length(), n)
    let core = @number.fold(digits, n, 10L)
    let accepted = if n == value.length() && core >= 0L {
      Some(core)
    } else {
      None
    }
    assert_eq(accepted, expected)
    let public = try
      request_framing(@mttp_core.Headers::of([("content-length", text)]))
    catch {
      ParseError(..) => None
    } noraise {
      Length(n) => Some(n)
      _ => fail("Content-Length lost its framing")
    }
    assert_eq(public, expected)
  }
}

///|
test "public chunk decoder agrees with the hex core at the signed bound" {
  let cases : Array[(String, Int64?)] = [
    ("0", Some(0L)),
    ("0001", Some(1L)),
    ("aF", Some(175L)),
    ("7fffffffffffffff", Some(9223372036854775807L)),
    ("7FFFFFFFFFFFFFFF", Some(9223372036854775807L)),
    ("0007fffffffffffffff", Some(9223372036854775807L)),
    ("8000000000000000", None),
    ("ffffffffffffffffffffffff", None),
    ("", None),
    ("+1", None),
    ("-1", None),
    (" 1", None),
    ("g", None),
  ]
  for (text, expected) in cases {
    let (digits, n) = number_prefix(text, hex=true)
    assert_eq(digits.length(), n)
    let value = @number.fold(digits, n, 16L)
    let core = if n == text.length() && value >= 0L {
      Some(value)
    } else {
      None
    }
    assert_eq(core, expected)
    let parsed = try chunk_size(text) catch {
      ParseError(..) => None
    } noraise {
      value => Some(value)
    }
    assert_eq(parsed, expected)
    let wire = Buffer()
    wire.write_bytes(@mttp_core.encode_utf8(text + "\r\n"))
    let decoder = ChunkedDecoder::new(Limits::default())
    let accepted = try decoder.feed(wire.to_bytes()) catch {
      ParseError(..) => false
    } noraise {
      decoded => {
        assert_eq(decoded.consumed, text.length() + 2)
        assert_eq(decoded.chunks, [])
        true
      }
    }
    assert_eq(accepted, expected is Some(_))
  }
  assert_eq(chunk_size("aF ; name=\"value\""), 175L)
}

///|
test "number wrappers preserve first error and whitespace handling" {
  for
    (text, detail) in [
      ("x9223372036854775808", "invalid Content-Length"),
      ("9223372036854775808x", "Content-Length overflow"),
      ("9223372036854775807x", "invalid Content-Length"),
      ("1\u{00a0}", "invalid Content-Length"),
    ] {
    try content_length(text) catch {
      ParseError(detail=actual, ..) => assert_eq(actual, detail)
    } noraise {
      _ => fail("accepted invalid Content-Length")
    }
  }
  for
    (text, detail) in [
      ("g8000000000000000", "invalid chunk size"),
      ("8000000000000000g", "chunk size overflow"),
      ("7fffffffffffffffg", "invalid chunk size or extension"),
      ("1 ", "invalid chunk size or extension"),
      ("1\t", "invalid chunk size or extension"),
      ("１２", "invalid chunk size"),
    ] {
    try chunk_size(text) catch {
      ParseError(detail=actual, ..) => assert_eq(actual, detail)
    } noraise {
      _ => fail("accepted invalid chunk size")
    }
  }
}
