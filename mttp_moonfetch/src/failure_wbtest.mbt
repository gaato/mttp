// How each moonfetch failure is classified, including the ones no local
// server here produces (HTTP/3 refusals, proxies, alerts on an established
// connection).

///|
fn classified(e : Error, phase : @mttp.Phase) -> (@mttp.Kind, @mttp.Phase) {
  let @mttp.TransportError(kind~, phase~, ..) = failure(e, phase)
  (kind, phase)
}

///|
test "failures that prove nothing was sent are unsent" {
  // InvalidAddr cannot be built outside its package; parsing makes one.
  let bad_address : Error = try {
    ignore(@socket.Addr::parse("1.2.3.4.5:80"))
    Failure("parsed")
  } catch {
    e => e
  }
  assert_true(bad_address is @socket.InvalidAddr, msg="\{bad_address}")
  let unsent : Array[(String, Error)] = [
    ("connect", @os_error.OSError(111, context="@socket.Tcp::connect()")),
    ("bad address", bad_address),
    ("certificate", @alert.Alert(level=Fatal, kind=UnknownCa)),
    ("handshake", @alert.Alert(level=Fatal, kind=HandshakeFailure)),
    ("h2 refused", @moonfetch.Reset(code=7)),
    ("h3 rejected", @http3.Fault(code=RequestRejected, detail="busy")),
    (
      "h2 stream limit",
      @http2.Order("past the server's SETTINGS_MAX_CONCURRENT_STREAMS"),
    ),
    ("h2 after goaway", @http2.Order("a new stream after the server's GOAWAY")),
    ("proxy", @moonfetch.Proxy("proxy.example:3128: CONNECT answered 407")),
    ("url", @moonfetch.Url("ftp://example.com")),
  ]
  for item in unsent {
    let (label, e) = item
    assert_true(failure(e, Unknown, bodiless=true).is_unsent(), msg=label)
  }
}

///|
test "a refused stream proves nothing for a request with a body, or after the head" {
  let refused = @moonfetch.Reset(code=7)
  let rejected = @http3.Fault(code=RequestRejected, detail="busy")
  // moonfetch raises REFUSED_STREAM itself when the connection dies while a
  // request body waits for window, after the head was written.
  assert_false(failure(refused, Unknown).is_unsent())
  assert_eq(classified(refused, Unknown), (Network, Unknown))
  assert_false(failure(refused, Body, bodiless=true).is_unsent())
  // H3_REQUEST_REJECTED comes only from the server, body or not.
  assert_true(failure(rejected, Unknown).is_unsent())
  assert_false(failure(rejected, Body).is_unsent())
}

///|
test "failures on an established connection may have been sent" {
  let sent : Array[(String, Error)] = [
    ("reset read", @os_error.OSError(104, context="@socket.Tcp::read()")),
    ("bad record", @alert.Alert(level=Fatal, kind=BadRecordMac)),
    ("close notify", @alert.Alert(level=Warning, kind=CloseNotify)),
    ("h2 internal error", @moonfetch.Reset(code=2)),
    ("h2 incomplete", @http2.Incomplete),
    ("h1 partial", @http1.Partial),
    ("h3 internal", @http3.Fault(code=InternalError, detail="")),
    ("h2 order", @http2.Order("a head on a stream this side has ended")),
    ("other", Failure("unexpected")),
  ]
  for item in sent {
    let (label, e) = item
    assert_false(failure(e, Unknown).is_unsent(), msg=label)
  }
}

///|
test "kinds follow the failure" {
  assert_eq(classified(@moonfetch.Url("x"), Unknown), (Invalid, Pool))
  assert_eq(
    classified(@moonfetch.Proxy("p: CONNECT answered 407"), Unknown),
    (Proxy(status=407), Dial),
  )
  assert_eq(
    classified(@moonfetch.Proxy("SOCKS5 refused: host unreachable"), Unknown),
    (Proxy(status=0), Dial),
  )
  assert_eq(
    classified(@moonfetch.Timeout(limit=5), Body),
    (Timeout(ms=5), Body),
  )
  assert_eq(
    classified(@moonfetch.Exceeded(limit=8, got=9), Body),
    (TooLarge(limit=8), Body),
  )
  assert_eq(
    classified(
      @http1.Malformed("the peer closed partway through a message"),
      Unknown,
    ),
    (Network, Unknown),
  )
  assert_eq(
    classified(@http1.Malformed("bad field"), Unknown),
    (Protocol, Unknown),
  )
  assert_eq(classified(@http2.ProtocolError("frame"), Body), (Protocol, Body))
  let original = @mttp.TransportError(kind=Closed, phase=Write, detail="kept")
  assert_eq(classified(original, Unknown), (Closed, Write))
}
