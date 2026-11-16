///|
test "the dictionary coding: dcz or dcb by weight, dcz at equal weights" {
  let pick = (value : String) => {
    dictionary_choice(@mttp_core.Headers::of([("accept-encoding", value)])).map(choice => {
        choice.0
      },
    )
  }
  assert_eq(pick("gzip, br, zstd, dcb, dcz"), Some(Dcz))
  assert_eq(pick("dcb"), Some(Dcb))
  assert_eq(pick("dcb;q=1, dcz;q=0.5"), Some(Dcb))
  assert_eq(pick("dcz;q=0, dcb;q=0"), None)
  assert_eq(pick("dcz, dcz;q=0"), None)
  assert_eq(pick("dcb, dcb;q=0"), None)
  assert_eq(pick("gzip, br"), None)
  assert_eq(pick("dcz;q=nope"), None)
  assert_eq(pick("dcz;level=1"), None)
  assert_eq(pick("dcz;q=1;x=2"), None)
  assert_eq(dictionary_choice(@mttp_core.Headers::empty()), None)
}

///|
test "dictionary_allowed follows RFC 9842 section 9.3.3" {
  let allowed = (
    request : Array[(String, String)],
    response : Array[(String, String)],
  ) => {
    dictionary_allowed(
      @mttp_core.Headers::of(request),
      @mttp_core.Headers::of(response),
    )
  }
  assert_true(allowed([], []))
  assert_true(allowed([("sec-fetch-site", "same-origin")], []))
  assert_true(allowed([("sec-fetch-site", "cross-site")], []))
  assert_true(
    allowed(
      [("sec-fetch-site", "cross-site"), ("sec-fetch-mode", "navigate")],
      [],
    ),
  )
  assert_true(
    allowed(
      [("sec-fetch-site", "same-site"), ("sec-fetch-mode", "same-origin")],
      [],
    ),
  )
  assert_false(
    allowed([("sec-fetch-site", "cross-site"), ("sec-fetch-mode", "no-cors")], []),
  )
  let cors = [
    ("sec-fetch-site", "cross-site"),
    ("sec-fetch-mode", "cors"),
    ("origin", "https://a.example"),
  ]
  assert_false(allowed(cors, []))
  assert_true(allowed(cors, [("access-control-allow-origin", "*")]))
  assert_true(
    allowed(cors, [("access-control-allow-origin", "https://a.example")]),
  )
  assert_false(
    allowed(cors, [("access-control-allow-origin", "https://b.example")]),
  )
  assert_false(
    allowed([("sec-fetch-site", "cross-site"), ("sec-fetch-mode", "cors")], [
      ("access-control-allow-origin", "*"),
    ]),
  )
  // Repeated fields are one combined value, which matches no origin.
  assert_false(
    allowed(cors, [
      ("access-control-allow-origin", "https://a.example"),
      ("access-control-allow-origin", "https://b.example"),
    ]),
  )
}
