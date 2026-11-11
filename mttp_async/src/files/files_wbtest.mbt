///|
test "content types follow the extension table and ignore case" {
  let cases = [
    ("index.html", "text/html; charset=utf-8"),
    ("page.htm", "text/html; charset=utf-8"),
    ("site.css", "text/css; charset=utf-8"),
    ("app.js", "text/javascript; charset=utf-8"),
    ("app.mjs", "text/javascript; charset=utf-8"),
    ("data.json", "application/json"),
    ("app.js.map", "application/json"),
    ("logo.svg", "image/svg+xml"),
    ("logo.png", "image/png"),
    ("photo.jpg", "image/jpeg"),
    ("photo.JPEG", "image/jpeg"),
    ("anim.gif", "image/gif"),
    ("photo.webp", "image/webp"),
    ("favicon.ico", "image/x-icon"),
    ("README.TXT", "text/plain; charset=utf-8"),
    ("module.wasm", "application/wasm"),
    ("font.woff2", "font/woff2"),
    ("archive.tar.gz", "application/octet-stream"),
    ("Makefile", "application/octet-stream"),
    (".css", "application/octet-stream"),
    ("trailing.", "application/octet-stream"),
  ]
  for case in cases {
    let (name, expected) = case
    assert_eq(content_type(name), expected, msg=name)
  }
}

///|
test "http_date writes IMF-fixdate within the four-digit years" {
  assert_eq(http_date(784111777L), Some("Sun, 06 Nov 1994 08:49:37 GMT"))
  assert_eq(http_date(0L), Some("Thu, 01 Jan 1970 00:00:00 GMT"))
  assert_eq(http_date(-1L), Some("Wed, 31 Dec 1969 23:59:59 GMT"))
  assert_eq(http_date(951782400L), Some("Tue, 29 Feb 2000 00:00:00 GMT"))
  assert_eq(http_date(-62135596800L), Some("Mon, 01 Jan 0001 00:00:00 GMT"))
  assert_eq(http_date(253402300799L), Some("Fri, 31 Dec 9999 23:59:59 GMT"))
  assert_eq(http_date(-62135596801L), None)
  assert_eq(http_date(253402300800L), None)
  // Each written date reads back to the same time.
  for seconds in [784111777L, 0L, -1L, 951782400L, 1767225599L] {
    let date = http_date(seconds).unwrap()
    assert_eq(
      @mttp.parse_http_date(date, now_unix_ms=0L),
      Some(seconds * 1000L),
      msg=date,
    )
  }
}
