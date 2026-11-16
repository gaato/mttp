///|
test "SOCKS CONNECT encodes numeric IPv4 IPv6 and mapped literals without domain DNS" {
  for
    (host, expected) in [
      ("127.0.0.1", b"\x05\x01\x00\x01\x7f\x00\x00\x01\x1f\x90"),
      ("::1", b"\x05\x01\x00\x04" + Bytes::make(15, 0) + b"\x01\x1f\x90"),
      (
        "2001:db8::abcd",
        b"\x05\x01\x00\x04\x20\x01\x0d\xb8" +
        Bytes::make(10, 0) +
        b"\xab\xcd\x1f\x90",
      ),
      (
        "::ffff:127.0.0.1",
        b"\x05\x01\x00\x04" +
        Bytes::make(10, 0) +
        b"\xff\xff\x7f\x00\x00\x01\x1f\x90",
      ),
      ("origin.test", b"\x05\x01\x00\x03\x0borigin.test\x1f\x90"),
    ] {
    let state = SocksHandshake::new(host, 8080, None)
    state.feed(b"\x05\x00")
    assert_eq(state.take_output(), expected, msg=host)
  }
}

///|
/// Feeds arbitrary transport pieces while observing each protocol read bound.
fn socks_feed(state : SocksHandshake, bytes : BytesView) -> Unit raise {
  for offset = 0; offset < bytes.length(); {
    let n = (state.need - state.reply.length()).min(bytes.length() - offset)
    state.feed(bytes[offset:offset + n])
    assert_true(state.reply.length() <= 262)
    continue offset + n
  }
}

///|
test "SOCKS handshake corpus succeeds at every split for all bound address forms" {
  let auth = socks_credentials("u:p").unwrap()
  let replies = [
    b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50",
    b"\x05\x00\x00\x04" + Bytes::make(16, 0) + b"\x00\x50",
    b"\x05\x00\x00\x03\x01a\x00\x50",
    b"\x05\x00\x00\x03\xff" + Bytes::make(255, b'a') + b"\x00\x50",
  ]
  for credentials in [None, Some(auth)] {
    for reply in replies {
      let transcript = (if credentials is Some(_) {
          b"\x05\x02\x01\x00"
        } else {
          b"\x05\x00"
        }) +
        reply
      for split in 0..<=transcript.length() {
        let state = SocksHandshake::new("origin.test", 443, credentials)
        assert_eq(
          state.take_output(),
          if credentials is Some(_) {
            b"\x05\x01\x02"
          } else {
            b"\x05\x01\x00"
          },
        )
        socks_feed(state, transcript[:split])
        socks_feed(state, transcript[split:])
        assert_eq(state.stage, 3)
        assert_eq(state.reply, b"")
      }
    }
  }
  let state = SocksHandshake::new("origin.test", 443, Some(auth))
  state.feed(b"\x05\x02")
  assert_eq(state.take_output(), b"\x01\x01u\x01p")
  state.feed(b"\x01\x00")
  assert_eq(state.take_output(), b"\x05\x01\x00\x03\x0borigin.test\x01\xbb")
}

///|
test "SOCKS refuses every reply code malformed version method reserved byte and address type" {
  for code in 1..<=255 {
    let state = SocksHandshake::new("example.test", 80, None)
    state.feed(b"\x05\x00")
    let reply : Bytes = [5, code.to_byte(), 0, 1]
    for split in 0..<=4 {
      let state = SocksHandshake::new("example.test", 80, None)
      state.feed(b"\x05\x00")
      try {
        socks_feed(state, reply[:split])
        socks_feed(state, reply[split:])
      } catch {
        @mttp_core.TransportError(kind~, phase~, ..) => {
          assert_eq(kind, Proxy(status=code))
          assert_eq(phase, Dial)
        }
        error => raise error
      } noraise {
        _ => fail("refusal accepted")
      }
    }
  }
  for
    (auth, input, kind) in [
      (None, b"\x04\x00", @mttp_core.Kind::Protocol),
      (None, b"\x05\xff", Proxy(status=407)),
      (None, b"\x05\x02", Proxy(status=407)),
      (Some(b"\x01\x01u\x01p"), b"\x05\x00", Proxy(status=407)),
      (Some(b"\x01\x01u\x01p"), b"\x05\x02\x01\x01", Proxy(status=407)),
      (Some(b"\x01\x01u\x01p"), b"\x05\x02\x02\x00", Protocol),
      (None, b"\x05\x00\x04\x00\x00\x01", Protocol),
      (None, b"\x05\x00\x05\x00\x01\x01", Protocol),
      (None, b"\x05\x00\x05\x00\x00\x02", Protocol),
      (None, b"\x05\x00\x05\x00\x00\x03\x00", Protocol),
    ] {
    for split in 0..<=input.length() {
      let state = SocksHandshake::new("example.test", 80, auth)
      try {
        socks_feed(state, input[:split])
        socks_feed(state, input[split:])
      } catch {
        @mttp_core.TransportError(kind=actual, phase=Dial, ..) =>
          assert_eq(actual, kind)
        error => raise error
      } noraise {
        _ => fail("malformed handshake accepted")
      }
    }
  }
}

///|
test "SOCKS username password target and reply bounds reject one past the limit" {
  assert_eq(socks_credentials("u%FF:p"), None)
  assert_eq(socks_credentials("u:p%FF"), None)
  assert_eq(socks_credentials("u"), None)
  assert_eq(socks_credentials(":p"), None)
  assert_eq(socks_credentials("u:"), None)
  assert_true(
    socks_credentials("u".repeat(255) + ":" + "p".repeat(255)) is Some(bytes) &&
    bytes.length() == 513,
  )
  assert_eq(socks_credentials("u".repeat(256) + ":p"), None)
  assert_eq(socks_credentials("u:" + "p".repeat(256)), None)
  assert_true(socks_credentials("%C3%A9:p") is Some(_))
  let state = SocksHandshake::new("a".repeat(255), 65535, None)
  assert_eq(state.request.length(), 262)
  for host in ["", "a".repeat(256)] {
    try SocksHandshake::new(host, 80, None) catch {
      @mttp_core.TransportError(kind=Invalid, phase=Dial, ..) => ()
      error => raise error
    } noraise {
      _ => fail("unbounded target accepted")
    }
  }
  try state.feed(b"\x05\x00x") catch {
    @mttp_core.TransportError(kind=Protocol, phase=Dial, ..) => ()
    error => raise error
  } noraise {
    _ => fail("oversized method reply accepted")
  }
  assert_eq(state.reply.length(), 0)
  let state = SocksHandshake::new("example.test", 80, None)
  state.feed(b"\x05\x00")
  state.feed(b"\x05\x00\x00\x03")
  state.feed(b"\xff")
  assert_eq(state.need, 262)
  try state.feed(Bytes::make(258, b'a')) catch {
    @mttp_core.TransportError(kind=Protocol, phase=Dial, ..) => ()
    error => raise error
  } noraise {
    _ => fail("263 byte CONNECT reply accepted")
  }
  assert_eq(state.reply.length(), 5)
}
