///|
fn gen_bytes(size : Int32) -> @qc.Generator[Bytes] {
  @qc.int_range(0, 256)
  .array_with_size(size)
  .map(a => Bytes::from_array(a.map(i => i.to_byte())))
}

///|
test "seeded encode parse round trips random heads payloads keys and roles" {
  let generator = @qc.elements([
      @frame.Opcode::Continuation,
      Text,
      Binary,
      Close,
      Ping,
      Pong,
    ])
    .zip(@qc.int_range(0, 300))
    .zip(@qc.int_range(0, 8))
    .zip(gen_bytes(4))
  for seed in 0UL..<80UL {
    let (((opcode, size), flags), key) = generator.sample(seed~)
    let control = opcode is Close || opcode is Ping || opcode is Pong
    let size = if control { size % 126 } else { size }
    let size = if opcode is Close && size == 1 { 2 } else { size }
    let payload = gen_bytes(size).sample(seed=seed + 100UL)
    let masked = (flags & 1) != 0
    let head = @frame.FrameHead::new(
      fin=control || (flags & 2) != 0,
      rsv1=!control && (flags & 4) != 0,
      opcode~,
      masked~,
      length=size.to_int64(),
    )
    let encoded = if masked {
      @frame.encode_head(head, mask=key) + @frame.apply_mask(payload, key)
    } else {
      @frame.encode_head(head) + payload
    }
    let role : @frame.Role = if masked { Server } else { Client }
    @sim.check_splits(encoded, pieces => {
      read_frames(pieces, role~, allow_rsv1=true)
    })
    let trace = read_frames(
      @sim.gen_chunks(encoded).sample(seed~),
      role~,
      allow_rsv1=true,
    )
    assert_eq(trace.heads, [head])
    assert_eq(trace.payloads, [payload])
    assert_eq(trace.ends, 1)
    assert_eq(trace.failure, None)
  }
}

///|
test "arbitrary bytes never hang and preserve partial events under every split" {
  for seed in 0UL..<120UL {
    let size = @qc.int_range(0, 64).sample(seed~)
    let bytes = gen_bytes(size).sample(seed=seed + 1000UL)
    for role in [@frame.Role::Client, Server] {
      @sim.check_splits(bytes, pieces => {
        read_frames(pieces, role~, limit=512, allow_rsv1=true)
      })
    }
  }
}

///|
test "masking at every offset and split equals whole masking including large offsets" {
  for seed in 0UL..<30UL {
    let key = gen_bytes(4).sample(seed~)
    let bytes = gen_bytes(40).sample(seed=seed + 50UL)
    for offset in [0, 1, 2, 3, 4, 2147483647] {
      let whole = @frame.apply_mask(bytes, key, offset~)
      assert_eq(@frame.apply_mask(whole, key, offset~), bytes)
      for cut in 0..<=bytes.length() {
        let a = @frame.apply_mask(bytes[:cut], key, offset~)
        let b = @frame.apply_mask(
          bytes[cut:],
          key,
          offset=(offset % 4 + cut) % 4,
        )
        assert_eq(a + b, whole)
      }
    }
  }
}

///|
test "encode length boundaries use minimal forms and retain all 63 length bits" {
  for
    (length, header) in [
      (0L, b"\x82\x00"),
      (125L, b"\x82\x7d"),
      (126L, b"\x82\x7e\x00\x7e"),
      (65535L, b"\x82\x7e\xff\xff"),
      (65536L, b"\x82\x7f\x00\x00\x00\x00\x00\x01\x00\x00"),
      (2147483647L, b"\x82\x7f\x00\x00\x00\x00\x7f\xff\xff\xff"),
      (9223372036854775807L, b"\x82\x7f\x7f\xff\xff\xff\xff\xff\xff\xff"),
    ] {
    let head = @frame.FrameHead::new(
      fin=true,
      opcode=Binary,
      masked=false,
      length~,
    )
    assert_eq(@frame.encode_head(head), header)
    @sim.check_splits(header, pieces => read_frames(pieces, limit=2147483647))
    let masked = { ..head, masked: true, }
    let masked_header = @frame.encode_head(masked, mask=b"\x00\xff\x80\x01")
    @sim.check_splits(masked_header, pieces => {
      read_frames(pieces, role=Server, limit=2147483647)
    })
    if length <= 2147483647L {
      assert_eq(read_frames([header], limit=2147483647).heads, [head])
      assert_eq(
        read_frames([masked_header], role=Server, limit=2147483647).heads,
        [masked],
      )
    }
  }
}

///|
test "encoding refuses negative lengths one-byte Close and inconsistent mask keys" {
  let head = @frame.FrameHead::new(
    fin=true,
    opcode=Binary,
    masked=false,
    length=0,
  )
  for
    (head, key) in [
      ({ ..head, length: -1L, }, None),
      ({ ..head, opcode: Close, length: 1L, }, None),
      (head, Some(b"abcd")),
      ({ ..head, masked: true, }, None),
      ({ ..head, masked: true, }, Some(b"abc")),
      ({ ..head, masked: true, }, Some(b"abcde")),
    ] {
    try @frame.encode_head(head, mask?=key) catch {
      @frame.FrameError(kind~, ..) =>
        assert_eq(kind, @frame.FrameErrorKind::Protocol)
    } noraise {
      _ => fail("invalid frame head was encoded")
    }
  }
  for (key, offset) in [(b"abc", 0), (b"abcde", 0), (b"abcd", -1)] {
    try @frame.apply_mask(b"x", key, offset~) catch {
      @frame.FrameError(kind~, ..) =>
        assert_eq(kind, @frame.FrameErrorKind::Protocol)
    } noraise {
      _ => fail("invalid mask was accepted")
    }
  }
}
