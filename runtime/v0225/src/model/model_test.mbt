///|
test "scan_head bounds and dup headers" {
  let h = b"GET / HTTP/1.1\r\nCookie: a=1\r\nCookie: b=2\r\n\r\nrest"
  guard scan_head(h[:], max=1024) is Some(n) else { fail("incomplete") }
  inspect(n, content="44")
  let hs = parse_head_headers(h[:n])
  inspect(hs.get_all("cookie").join("|"), content="a=1|b=2")
  inspect(scan_head(b"GET / HTTP/1.1\r\nX: y"[:], max=1024), content="None")
  let big = Bytes::make(2000, b'a')
  let refused = try {
    ignore(scan_head(big[:], max=1024))
    false
  } catch {
    _ => true
  }
  inspect(refused, content="true")
}
