///|
test "quoted relation unescapes backslashes" {
  assert_eq(
    @client.parse_link_next(
      @mttp_core.Headers::of([("link", "</next>; rel=\"ne\\xt\"")]),
    ),
    Some("/next"),
  )
}

///|
test "parse_link_next handles repeated values comma URLs and relation forms" {
  let mut headers = @mttp_core.Headers::empty()
  assert_eq(@client.parse_link_next(headers), None)
  headers = headers.add("Link", "<https://api.test/prev>; rel=prev")
  headers = headers.add(
    "link", "<https://api.test/items?a=1,2>; title=\"a,b\"; rel=\"last next\", <https://api.test/other>; rel=last",
  )
  assert_eq(
    @client.parse_link_next(headers),
    Some("https://api.test/items?a=1,2"),
  )
  let unquoted = @mttp_core.Headers::of([
    ("link", "<cursor-1>; REL=next, <cursor-2>; rel=last"),
  ])
  assert_eq(@client.parse_link_next(unquoted), Some("cursor-1"))
  let escaped = @mttp_core.Headers::of([
    (
      "link", "<ignored>; title=\"x\\\";y\"; rel=prev, <chosen>; rel=\"NEXT last\"",
    ),
  ])
  assert_eq(@client.parse_link_next(escaped), Some("chosen"))
  assert_eq(
    @client.parse_link_next(
      @mttp_core.Headers::of([("link", "not-a-link; rel=next")]),
    ),
    None,
  )
}

///|
test "only the first rel parameter of a link value counts" {
  // RFC 8288 §3.3: occurrences after the first MUST be ignored.
  let later_next = @mttp_core.Headers::of([
    ("link", "<skipped>; rel=prev; rel=next, <chosen>; rel=next"),
  ])
  assert_eq(@client.parse_link_next(later_next), Some("chosen"))
  let first_next = @mttp_core.Headers::of([
    ("link", "<chosen>; title=x; rel=next; rel=prev"),
  ])
  assert_eq(@client.parse_link_next(first_next), Some("chosen"))
}
