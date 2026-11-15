///|
#derive(Eq, Debug)
priv struct Trace {
  heads : Array[@frame.FrameHead]
  payloads : Array[Bytes]
  ends : Int32
  failure : @frame.FrameErrorKind?
}

///|
// Normalize only Payload piece boundaries: Head and End remain observable,
// including a partial final frame. The progress budget detects a stuck next.
fn read_frames(
  pieces : Array[Bytes],
  role~ : @frame.Role = Client,
  limit~ : Int32 = 1048576,
  allow_rsv1~ : Bool = false,
) -> Trace raise {
  let parser = @frame.Parser::new(role~, max_frame_bytes=limit, allow_rsv1~)
  let heads = []
  let payloads : Array[Buffer] = []
  let mut ends = 0
  let mut budget = pieces.fold(init=3, (n, p) => n + 3 * p.length()) +
    pieces.length()
  for piece in pieces {
    parser.feed(piece)
    for ;; {
      budget -= 1
      assert_true(budget >= 0, msg="parser next made no progress")
      let event = parser.next() catch {
        @frame.FrameError(kind~, ..) =>
          return {
            heads,
            payloads: payloads.map(buffer => buffer.to_bytes()),
            ends,
            failure: Some(kind),
          }
      }
      match event {
        None => break
        Some(Head(head)) => {
          heads.push(head)
          payloads.push(Buffer())
        }
        Some(Payload(bytes)) => {
          assert_true(!bytes.is_empty())
          let i = payloads.length() - 1
          payloads[i].write_bytes(bytes)
        }
        Some(End) => ends += 1
      }
    }
  }
  {
    heads,
    payloads: payloads.map(buffer => buffer.to_bytes()),
    ends,
    failure: None,
  }
}

///|
test "RFC 6455 frame corpus is identical whole at every split and byte by byte" {
  let binary256 = Bytes::makei(256, i => i.to_byte())
  let cases : Array[(String, @frame.Role, Bytes, Array[Bytes])] = [
    ("unmasked Hello", Client, b"\x81\x05Hello", [b"Hello"]),
    (
      "masked Hello",
      Server,
      b"\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58",
      [b"Hello"],
    ),
    ("fragmented Hello", Client, b"\x01\x03Hel\x80\x02lo", [b"Hel", b"lo"]),
    ("Ping", Client, b"\x89\x05Hello", [b"Hello"]),
    (
      "masked Pong",
      Server,
      b"\x8a\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58",
      [b"Hello"],
    ),
    ("256-byte binary", Client, b"\x82\x7e\x01\x00" + binary256, [binary256]),
    (
      "empty frames",
      Client,
      b"\x81\x00\x82\x00\x88\x00\x89\x00\x8a\x00",
      [b"", b"", b"", b"", b""],
    ),
    ("empty masked", Server, b"\x82\x80abcd", [b""]),
    (
      "Close with code and reason",
      Client,
      b"\x88\x05\x03\xe8bye",
      [b"\x03\xe8bye"],
    ),
    // ws owns CloseCode and CloseFrame: frame syntax returns their raw
    // bytes so the session can validate the code and UTF-8 reason together.
    ("Close code belongs to ws", Client, b"\x88\x02\x03\xed", [b"\x03\xed"]),
    (
      "Close reason belongs to ws",
      Client,
      b"\x88\x03\x03\xe8\xff",
      [b"\x03\xe8\xff"],
    ),
    (
      "interleaved control",
      Client,
      b"\x01\x01a\x89\x01?\x00\x01b\x80\x01c",
      [b"a", b"?", b"b", b"c"],
    ),
  ]
  for (name, role, wire, expected) in cases {
    @sim.check_splits(wire, pieces => read_frames(pieces, role~))
    let trace = read_frames([wire], role~)
    assert_eq(trace.failure, None, msg=name)
    assert_eq(trace.payloads, expected, msg=name)
    assert_eq(trace.ends, expected.length(), msg=name)
    assert_eq(trace.heads.length(), expected.length(), msg=name)
  }
  // RFC 5.7's 64 KiB example exercises every split through its payload too.
  let header = b"\x82\x7f\x00\x00\x00\x00\x00\x01\x00\x00"
  @sim.check_splits(header, pieces => read_frames(pieces))
  let payload = Bytes::make(65536, b'x')
  @sim.check_splits(header + payload, pieces => read_frames(pieces))
  let trace = read_frames([
    header,
    payload[:32768].to_owned(),
    payload[32768:].to_owned(),
  ])
  assert_eq(trace.payloads, [payload])
  assert_eq(trace.ends, 1)
  assert_eq(trace.failure, None)
}

///|
test "refused frame corpus rejects each head rule by kind under every split" {
  let cases : Array[(String, @frame.Role, Bytes)] = [
    ("server refuses unmasked", Server, b"\x81\x00"),
    ("client refuses masked", Client, b"\x81\x80"),
    ("RSV1", Client, b"\xc1\x00"),
    ("RSV2", Client, b"\xa1\x00"),
    ("RSV3", Client, b"\x91\x00"),
    ("length top bit", Client, b"\x82\x7f\x80\x00\x00\x00\x00\x00\x00\x00"),
    ("126 under 126", Client, b"\x82\x7e\x00\x7d"),
    ("127 under 65536", Client, b"\x82\x7f\x00\x00\x00\x00\x00\x00\xff\xff"),
    ("127 under 126", Client, b"\x82\x7f\x00\x00\x00\x00\x00\x00\x00\x00"),
    ("one-byte Close", Client, b"\x88\x01"),
  ]
  for op in [8, 9, 10] {
    cases.push(
      ("fragmented control", Client, Bytes::from_array([op.to_byte(), b'\x00'])),
    )
    cases.push(
      (
        "large control",
        Client,
        Bytes::from_array([(0x80 | op).to_byte(), b'\x7e']),
      ),
    )
  }
  for op in [3, 4, 5, 6, 7, 11, 12, 13, 14, 15] {
    cases.push(
      (
        "reserved opcode",
        Client,
        Bytes::from_array([(0x80 | op).to_byte(), b'\x00']),
      ),
    )
  }
  for (name, role, wire) in cases {
    @sim.check_splits(wire, pieces => read_frames(pieces, role~))
    let trace = read_frames([wire], role~)
    assert_eq(trace.failure, Some(@frame.FrameErrorKind::Protocol), msg=name)
    assert_eq(trace.heads.length(), 0, msg=name)
  }
}

///|
test "frame limit accepts exact bound and refuses overflow before payload or mask" {
  for
    (limit, header, too_big) in [
      (0, b"\x82\x00", b"\x82\x01"),
      (125, b"\x82\x7d", b"\x82\x7e\x00\x7e"),
      (65535, b"\x82\x7e\xff\xff", b"\x82\x7f\x00\x00\x00\x00\x00\x01\x00\x00"),
      (
        65536, b"\x82\x7f\x00\x00\x00\x00\x00\x01\x00\x00", b"\x82\x7f\x00\x00\x00\x00\x00\x01\x00\x01",
      ),
    ] {
    assert_eq(read_frames([header], limit~).heads.length(), 1)
    @sim.check_splits(too_big, pieces => read_frames(pieces, limit~))
    let trace = read_frames([too_big], limit~)
    assert_eq(trace.failure, Some(@frame.FrameErrorKind::TooLarge(limit~)))
    assert_eq(trace.heads.length(), 0)
    // A missing mask key cannot delay TooLarge.
    let masked = Bytes::makei(too_big.length(), i => {
      if i == 1 {
        too_big[i] | b'\x80'
      } else {
        too_big[i]
      }
    })
    assert_eq(read_frames([masked], role=Server, limit~).failure, trace.failure)
  }
  let trace = read_frames(
    [b"\x82\x7f\x7f\xff\xff\xff\xff\xff\xff\xff"],
    limit=2147483647,
  )
  assert_eq(
    trace.failure,
    Some(@frame.FrameErrorKind::TooLarge(limit=2147483647)),
  )
  assert_eq(
    read_frames([b""], limit=-1).failure,
    Some(@frame.FrameErrorKind::Protocol),
  )
}

///|
test "control payload bound accepts 125 refuses 126 and extensions never mark controls" {
  for op in [@frame.Opcode::Close, Ping, Pong] {
    let head = @frame.FrameHead::new(
      fin=true,
      opcode=op,
      masked=false,
      length=125,
    )
    let wire = @frame.encode_head(head) + Bytes::make(125, b'x')
    @sim.check_splits(wire, pieces => read_frames(pieces))
    assert_eq(read_frames([wire]).ends, 1)
    for
      bad in [
        { ..head, length: 126, },
        { ..head, fin: false, },
        { ..head, rsv1: true, },
      ] {
      assert_true(
        (try @frame.encode_head(bad) catch {
          @frame.FrameError(..) => None
        } noraise {
          _ => Some(())
        })
        is None,
      )
    }
    let marked = Bytes::from_array([wire[0] | b'\x40', b'\x00'])
    assert_eq(
      read_frames([marked], allow_rsv1=true).failure,
      Some(@frame.FrameErrorKind::Protocol),
    )
  }
  let head = @frame.FrameHead::new(
    fin=true,
    rsv1=true,
    opcode=Text,
    masked=false,
    length=1,
  )
  let wire = @frame.encode_head(head) + b"x"
  @sim.check_splits(wire, pieces => read_frames(pieces, allow_rsv1=true))
  assert_eq(read_frames([wire], allow_rsv1=true).heads, [head])
  for wire in [b"\xa1\x00", b"\x91\x00"] {
    assert_eq(
      read_frames([wire], allow_rsv1=true).failure,
      Some(@frame.FrameErrorKind::Protocol),
    )
  }
}

///|
test "parser errors are sticky after next and feed and map to close codes" {
  for
    (limit, wire, expected) in [
      (0, b"\x82\x01", @frame.FrameErrorKind::TooLarge(limit=0)),
      (10, b"\x83\x00", @frame.FrameErrorKind::Protocol),
      (-1, b"", @frame.FrameErrorKind::Protocol),
    ] {
    let parser = @frame.Parser::new(
      role=Client,
      max_frame_bytes=limit,
      allow_rsv1=false,
    )
    parser.feed(wire)
    let mut detail = None
    for _ in 0..<3 {
      try {
        ignore(parser.next())
        fail("expected sticky failure")
      } catch {
        @frame.FrameError(kind~, detail=text) => {
          assert_eq(kind, expected)
          if detail is Some(previous) {
            assert_eq(text, previous)
          }
          detail = Some(text)
        }
        error => raise error
      }
      parser.feed(b"\x82\x00")
    }
  }
  assert_eq(@frame.FrameErrorKind::Protocol.close_code(), 1002)
  assert_eq(@frame.FrameErrorKind::TooLarge(limit=3).close_code(), 1009)
}

///|
test "payload delivery is incremental and feed may queue views across frames" {
  let parser = @frame.Parser::new(
    role=Server,
    max_frame_bytes=5,
    allow_rsv1=false,
  )
  assert_eq(parser.next(), None)
  parser.feed(b"\x81\x85\x37\xfa\x21\x3d")
  assert_true(parser.next() is Some(Head(_)))
  assert_eq(parser.next(), None)
  parser.feed(b"\x7f\x9f")
  assert_eq(parser.next(), Some(@frame.Event::Payload(b"He")))
  assert_eq(parser.next(), None)
  parser.feed(b"\x4d\x51\x58\x82")
  parser.feed(b"")
  parser.feed(b"\x80abcd")
  assert_eq(parser.next(), Some(@frame.Event::Payload(b"llo")))
  assert_eq(parser.next(), Some(@frame.Event::End))
  assert_true(parser.next() is Some(Head({ length: 0L, .. })))
  assert_eq(parser.next(), Some(@frame.Event::End))
  assert_eq(parser.next(), None)
}
