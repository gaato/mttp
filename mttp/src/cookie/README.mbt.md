# gaato/mttp/cookie

An [RFC 6265](https://www.rfc-editor.org/rfc/rfc6265) cookie store for HTTP
clients, without I/O. `CookieJar::store` reads every `Set-Cookie` of a
response for the URL that was requested; `header_for` and `attach` give the
`Cookie` header a request to a URL should carry. Domain and path matching,
host-only cookies, `Secure`, `HttpOnly`, `SameSite`, the `__Secure-` and
`__Host-` prefixes and the storage order follow RFC 6265 and its successor
draft, RFC 6265bis.

The jar reads time from the `@rt.Clock` it is given, so expiry is
deterministic in tests. It is bounded:

- 50 cookies per domain and 3000 in all by default (`max_per_domain`,
  `max_total`); past a cap, expired cookies go first, then the least recently
  sent;
- a cookie whose name and value exceed 4096 bytes, or an attribute past 1024
  bytes, is ignored;
- no cookie lives longer than 400 days.

Without a public-suffix list, only single-label domains count as public
suffixes; pass `is_public_suffix` to refuse more `Domain` values. A host
written with the root dot (`example.com.`) is a different host from
`example.com`, as in browsers, and `Domain=com.` is still a single label.

```mbt check
///|
test "store a response's cookies and send them back" {
  let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
  let jar = @cookie.CookieJar::new(clock)
  jar.store(
    @http.Headers::of([
      ("Set-Cookie", "sid=abc; Path=/; Secure; HttpOnly"),
      ("Set-Cookie", "theme=dark; Max-Age=60"),
    ]),
    "https://example.com/login",
  )
  assert_eq(jar.header_for("https://example.com/"), Some("sid=abc; theme=dark"))
  // Secure cookies stay off plain HTTP.
  assert_eq(jar.header_for("http://example.com/"), Some("theme=dark"))
  clock.advance(61_000)
  assert_eq(jar.header_for("https://example.com/"), Some("sid=abc"))
}
```
