///|
test "session parser rejects authenticated malformed payloads before exposing values" {
  let signed = (payload : Bytes) => {
    "session=\{@base64.encode(payload)}.\{@base64.encode(payload)}"
  }
  for
    payload in [
      b"\xff", b"not json", b"{}", b"[\"bad\",{}]", b"[\"1000\",{\"x\":42}]", b"[\"0\",{}]",
    ] {
    let request = @mttp_core.Request::get("/").set_header(
      "cookie",
      signed(payload),
    )
    assert_true(
      read_session(request, "session", 4096, 0, (p, s) => p == s).is_empty(),
    )
  }
  let good = b"[\"1000\",{\"x\":\"y\"}]"
  let request = @mttp_core.Request::get("/").set_header("cookie", signed(good))
  assert_eq(
    read_session(request, "session", 4096, 0, (p, s) => p == s).get("x"),
    Some("y"),
  )
  assert_true(
    read_session(request, "session", 4096, 0, (_, _) => false).is_empty(),
  )
  // Replace the payload/expiry while keeping the original signature.
  let tampered = "session=\{@base64.encode(b"[\"2000\",{\"x\":\"z\"}]")}.\{@base64.encode(good)}"
  assert_true(
    read_session(
      @mttp_core.Request::get("/").set_header("cookie", tampered),
      "session",
      4096,
      0,
      (p, s) => p == s,
    ).is_empty(),
  )
}
