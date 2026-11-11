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
