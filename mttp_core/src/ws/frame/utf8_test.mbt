///|
fn core_utf8_valid(bytes : Bytes) -> Bool {
  try @utf8.decode(bytes) catch {
    _ => false
  } noraise {
    _ => true
  }
}

///|
fn validate_utf8(pieces : Array[Bytes]) -> Bool {
  let validator = @frame.Utf8Validator::new()
  for piece in pieces {
    if !validator.push(piece) {
      return false
    }
  }
  validator.finish()
}

///|
// Encode raw numeric values too, so surrogate and above-Unicode boundary
// vectors are independent of core's valid-Char constructors.
fn raw_utf8(cp : Int32) -> Bytes {
  let bytes = if cp < 0x80 {
    [cp]
  } else if cp < 0x800 {
    [0xc0 | (cp >> 6), 0x80 | (cp & 63)]
  } else if cp < 0x10000 {
    [0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63)]
  } else {
    [
      0xf0 | (cp >> 18),
      0x80 | ((cp >> 12) & 63),
      0x80 | ((cp >> 6) & 63),
      0x80 | (cp & 63),
    ]
  }
  Bytes::from_array(bytes.map(b => b.to_byte()))
}

///|
test "UTF-8 agrees with core at every code point boundary under every split" {
  for
    boundary in [
      0, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xd800, 0xdfff, 0xe000, 0xffff, 0x10000,
      0x10ffff, 0x110000,
    ] {
    for delta in [-1, 0, 1] {
      let cp = boundary + delta
      if cp < 0 {
        continue
      }
      let bytes = raw_utf8(cp)
      let expected = cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff)
      assert_eq(core_utf8_valid(bytes), expected)
      assert_eq(validate_utf8([bytes]), expected)
      @sim.check_splits(bytes, pieces => validate_utf8(pieces))
    }
  }
}

///|
test "seeded strict UTF-8 agrees with core for random bytes and random code points" {
  for seed in 0UL..<200UL {
    let bytes = gen_bytes(@qc.int_range(0, 32).sample(seed~)).sample(
      seed=seed + 500UL,
    )
    assert_eq(validate_utf8([bytes]), core_utf8_valid(bytes))
    @sim.check_splits(bytes, pieces => validate_utf8(pieces))
    let points = @qc.int_range(0, 0x110000).array_with_size(8).sample(seed~)
    let out = Buffer()
    for cp in points {
      out.write_bytes(raw_utf8(cp))
    }
    let text = out.to_bytes()
    assert_eq(validate_utf8([text]), core_utf8_valid(text))
    @sim.check_splits(text, pieces => validate_utf8(pieces))
  }
}

///|
test "UTF-8 refuses overlongs surrogates out of range and bad continuations immediately" {
  for
    invalid in [
      b"\x80", b"\xbf", b"\xc0", b"\xc1", b"\xf5", b"\xff", b"\xe0\x80", b"\xed\xa0",
      b"\xf0\x80", b"\xf4\x90", b"\xc2x", b"\xe1\x80x", b"\xf1\x80\x80x",
    ] {
    let validator = @frame.Utf8Validator::new()
    if invalid.length() > 1 {
      assert_true(validator.push(invalid[:invalid.length() - 1]))
    }
    assert_false(validator.push(invalid[invalid.length() - 1:]))
    assert_false(validator.push(b"valid"))
    assert_false(validator.push(b""))
    assert_false(validator.finish())
    assert_false(core_utf8_valid(invalid))
    @sim.check_splits(invalid, pieces => validate_utf8(pieces))
  }
  for
    text in [
      b"\xc2\x80", b"\xe0\xa0\x80", b"\xed\x9f\xbf", b"\xf0\x90\x80\x80", b"\xf4\x8f\xbf\xbf",
    ] {
    for cut in 1..<text.length() {
      let validator = @frame.Utf8Validator::new()
      assert_true(validator.push(text[:cut]))
      assert_false(validator.finish())
      assert_false(core_utf8_valid(text[:cut].to_owned()))
      assert_true(validator.push(text[cut:]))
      assert_true(validator.finish())
      assert_true(validator.finish())
    }
  }
  assert_true(@frame.Utf8Validator::new().finish())
}
