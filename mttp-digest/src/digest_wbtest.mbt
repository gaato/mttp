///|
test "parse_challenges splits WWW-Authenticate values" {
  let cases : Array[(String, Array[(String, Array[(String, String)])])] = [
    (
      "Digest realm=\"a\", nonce=\"b\"",
      [("digest", [("realm", "a"), ("nonce", "b")])],
    ),
    (
      "Basic realm=\"x\", Digest realm=\"y\", nonce=n",
      [
        ("basic", [("realm", "x")]),
        ("digest", [("realm", "y"), ("nonce", "n")]),
      ],
    ),
    (
      "Negotiate abc+/==, Digest realm=\"r\\\"q\\\\\", nonce=n1",
      [("negotiate", []), ("digest", [("realm", "r\"q\\"), ("nonce", "n1")])],
    ),
    (
      "Digest realm=\"a, b\", qop=\"auth,auth-int\", nonce=\"x\"",
      [
        (
          "digest",
          [("realm", "a, b"), ("qop", "auth,auth-int"), ("nonce", "x")],
        ),
      ],
    ),
    (
      ", ,Digest  Realm = \"a\" ,, NONCE=b/c==,",
      [("digest", [("realm", "a"), ("nonce", "b/c==")])],
    ),
    ("DIGEST", [("digest", [])]),
    ("Bearer, Basic", [("bearer", []), ("basic", [])]),
    ("Bearer , ", [("bearer", [])]),
    ("Basic YWxhZGRpbjpvcGVuc2VzYW1l", [("basic", [])]),
    ("Digest realm=\"abc", [("digest", [("realm", "abc")])]),
    ("\"junk, more\", Digest realm=a", [("digest", [("realm", "a")])]),
    ("Digest realm=a junk", [("digest", [("realm", "a")]), ("junk", [])]),
    ("Digest nonce=n, realm=", [("digest", [("nonce", "n"), ("realm", "")])]),
    // `realm=` before a comma is a token68 in RFC 9110's grammar.
    ("Digest realm=, nonce=n", [("digest", []), ("nonce", [])]),
    ("", []),
  ]
  for case in cases {
    assert_eq(parse_challenges(case.0), case.1, msg=case.0)
  }
}

///|
/// What `digest_challenge` made of a challenge, as a string to compare.
fn describe(challenge : DigestChallenge?) -> String {
  guard challenge is Some(c) else { return "none" }
  let qop = match c.qop {
    Some(Auth) => "auth"
    Some(AuthInt) => "auth-int"
    None => "-"
  }
  let flags = [
    (c.stale, "stale"),
    (c.userhash, "userhash"),
    (c.opaque_data is Some(_), "opaque"),
  ].filter_map(flag => if flag.0 { Some(flag.1) } else { None })
  [c.realm, c.nonce, algorithm_name(c), qop, ..flags].join(" ")
}

///|
test "digest_challenge reads a challenge it can answer" {
  let base = [("realm", "r"), ("nonce", "n")]
  let cases : Array[(Array[(String, String)], Bool, String)] = [
    ([..base, ("qop", "auth")], false, "r n MD5 auth"),
    (base, false, "r n MD5 -"),
    ([..base, ("algorithm", "md5"), ("qop", "auth")], false, "r n MD5 auth"),
    (
      [..base, ("algorithm", "MD5-sess"), ("qop", "auth")],
      false,
      "r n MD5-sess auth",
    ),
    (
      [..base, ("algorithm", "SHA-256"), ("qop", "auth")],
      false,
      "r n SHA-256 auth",
    ),
    (
      [..base, ("algorithm", "sha-256-SESS"), ("qop", "auth")],
      false,
      "r n SHA-256-sess auth",
    ),
    ([..base, ("algorithm", "SHA-512-256"), ("qop", "auth")], false, "none"),
    ([..base, ("algorithm", "MD5-sess")], false, "none"),
    ([..base, ("qop", " auth-int , auth ")], false, "r n MD5 auth"),
    ([..base, ("qop", "auth-int")], true, "r n MD5 auth-int"),
    ([..base, ("qop", "auth-int")], false, "none"),
    ([..base, ("qop", "auth-conf")], true, "none"),
    (
      [..base, ("qop", "auth"), ("stale", "TRUE"), ("userhash", "true")],
      false,
      "r n MD5 auth stale userhash",
    ),
    (
      [..base, ("qop", "auth"), ("stale", "false"), ("opaque", "o")],
      false,
      "r n MD5 auth opaque",
    ),
    ([("realm", "r"), ("qop", "auth")], false, "none"),
    ([("nonce", "n"), ("qop", "auth")], false, "none"),
    ([..base, ("realm", "second"), ("qop", "auth")], false, "r n MD5 auth"),
  ]
  for case in cases {
    assert_eq(
      describe(digest_challenge(case.0, case.1)),
      case.2,
      msg=@debug.to_string(case.0),
    )
  }
}

///|
test "find_digest_challenge takes the first one it can answer, across headers" {
  let headers = @model.Headers::of([
    ("WWW-Authenticate", "Basic realm=\"b\""),
    (
      "WWW-Authenticate", "Digest realm=\"x\", nonce=\"1\", algorithm=SHA-512-256, qop=auth, Digest realm=\"y\", nonce=\"2\", algorithm=SHA-256, qop=auth",
    ),
    ("WWW-Authenticate", "Digest realm=\"z\", nonce=\"3\", qop=auth"),
  ])
  assert_eq(describe(find_digest_challenge(headers, false)), "y 2 SHA-256 auth")
  let none = @model.Headers::of([("WWW-Authenticate", "Bearer")])
  assert_eq(describe(find_digest_challenge(none, false)), "none")
}

///|
/// The RFC 7616 §3.9.1 challenge with `algorithm`.
fn rfc7616(algorithm : String) -> DigestChallenge {
  digest_challenge(
    [
      ("realm", "http-auth@example.org"),
      ("qop", "auth, auth-int"),
      ("algorithm", algorithm),
      ("nonce", "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v"),
      ("opaque", "FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"),
    ],
    false,
  ).unwrap()
}

///|
test "digest_authorization: RFC 7616 §3.9.1, SHA-256 and MD5" {
  let cnonce = "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ"
  let answer = (algorithm : String) => {
    digest_authorization(
      rfc7616(algorithm),
      "Mufasa",
      "Circle of Life",
      "GET",
      "/dir/index.html",
      1,
      cnonce,
      None,
    )
  }
  assert_eq(
    answer("SHA-256"),
    "Digest username=\"Mufasa\", realm=\"http-auth@example.org\", uri=\"/dir/index.html\", algorithm=SHA-256, nonce=\"7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v\", nc=00000001, cnonce=\"f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ\", qop=auth, response=\"753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1\", opaque=\"FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS\"",
  )
  assert_eq(
    answer("MD5"),
    "Digest username=\"Mufasa\", realm=\"http-auth@example.org\", uri=\"/dir/index.html\", algorithm=MD5, nonce=\"7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v\", nc=00000001, cnonce=\"f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ\", qop=auth, response=\"8ca523f5e9506fed4657c9700eebdbec\", opaque=\"FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS\"",
  )
}

///|
test "digest_authorization: RFC 2617 §3.5, and RFC 2069 without qop" {
  let params = [
    ("realm", "testrealm@host.com"),
    ("nonce", "dcd98b7102dd2f0e8b11d0f600bfb0c093"),
    ("opaque", "5ccc069c403ebaf9f0171e9517f40e41"),
  ]
  let answer = (params : Array[(String, String)]) => {
    digest_authorization(
      digest_challenge(params, false).unwrap(),
      "Mufasa",
      "Circle Of Life",
      "GET",
      "/dir/index.html",
      1,
      "0a4f113b",
      None,
    )
  }
  assert_eq(
    answer([..params, ("qop", "auth,auth-int")]),
    "Digest username=\"Mufasa\", realm=\"testrealm@host.com\", uri=\"/dir/index.html\", algorithm=MD5, nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", nc=00000001, cnonce=\"0a4f113b\", qop=auth, response=\"6629fae49393a05397450978507c4ef1\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"",
  )
  assert_eq(
    answer(params),
    "Digest username=\"Mufasa\", realm=\"testrealm@host.com\", uri=\"/dir/index.html\", algorithm=MD5, nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", response=\"670fd8c2df070c60b045671b8b24ff02\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"",
  )
}

///|
test "digest_authorization: sessions, auth-int, userhash and username*" {
  let cnonce = "80000000800000008000000080000000"
  let challenge = (params : Array[(String, String)], body_in_memory : Bool) => {
    digest_challenge([("realm", "r"), ("nonce", "n"), ..params], body_in_memory).unwrap()
  }
  let response = (header : String) => {
    let start = header.find("response=\"").unwrap() + 10
    header[start:start + header[start:].find("\"").unwrap()].to_owned()
  }
  let cases : Array[
    (String, DigestChallenge, String, String, Int64, Bytes?, String),
  ] = [
    (
      "MD5-sess",
      challenge([("algorithm", "MD5-sess"), ("qop", "auth")], false),
      "GET",
      "/x",
      1,
      None,
      "a777f56137f78b0ff56191b899ae16ab",
    ),
    (
      "SHA-256-sess",
      challenge([("algorithm", "SHA-256-sess"), ("qop", "auth")], false),
      "GET",
      "/x",
      1,
      None,
      "aa383e42b6344423638fcd3fbb904cd4963d951a27782888d23ca0d351ea8782",
    ),
    (
      "auth-int",
      challenge([("algorithm", "SHA-256"), ("qop", "auth-int")], true),
      "POST",
      "/x?q=1",
      3,
      Some(b"hello"),
      "a25b02d823dc55954662c7040b1489a79f36598340be50354e9a6f8aa06d392a",
    ),
  ]
  for case in cases {
    let header = digest_authorization(
      case.1,
      "u",
      "p",
      case.2,
      case.3,
      case.4,
      cnonce,
      case.5,
    )
    assert_eq(response(header), case.6, msg=case.0)
  }
  let header = digest_authorization(
    challenge([("algorithm", "SHA-256-sess"), ("qop", "auth")], false),
    "u",
    "p",
    "GET",
    "/x",
    1,
    cnonce,
    None,
  )
  assert_true(header.contains(", algorithm=SHA-256-sess, "))
  let header = digest_authorization(
    challenge([("algorithm", "SHA-256"), ("qop", "auth-int")], true),
    "u",
    "p",
    "POST",
    "/x?q=1",
    3,
    cnonce,
    Some(b"hello"),
  )
  assert_true(header.contains(", nc=00000003, "))
  assert_true(header.contains(", qop=auth-int, "))
  let userhash = rfc7616("SHA-256")
  let userhash = { ..userhash, userhash: true, }
  let header = digest_authorization(
    userhash,
    "Mufasa",
    "Circle of Life",
    "GET",
    "/dir/index.html",
    1,
    cnonce,
    None,
  )
  assert_true(
    header.has_prefix(
      "Digest username=\"a947aad205e80e429958a387394944c6b496301e79f89d35a4cc23b6ee12b5b6\", ",
    ),
  )
  assert_true(header.has_suffix(", userhash=true"))
  assert_eq(
    response(header),
    "1533fd14d2a9448ea55bd4eca0a54f5ef9387326d926a7350fe6a3c2357f454f",
  )
  // RFC 7616 §3.4.4's example of username*.
  let header = digest_authorization(
    challenge([("qop", "auth")], false),
    "Jäsøn Doe",
    "p",
    "GET",
    "/",
    1,
    cnonce,
    None,
  )
  assert_true(
    header.has_prefix("Digest username*=UTF-8''J%C3%A4s%C3%B8n%20Doe, "),
  )
  assert_eq(response(header), "323318df2d94606876c6bf0541caccac")
  let quoted = digest_authorization(
    digest_challenge([("realm", "a\"b\\c"), ("nonce", "n")], false).unwrap(),
    "say \"hi\"",
    "p",
    "GET",
    "/",
    1,
    cnonce,
    None,
  )
  assert_true(
    quoted.has_prefix(
      "Digest username=\"say \\\"hi\\\"\", realm=\"a\\\"b\\\\c\", ",
    ),
  )
}

///|
test "nonce state: counted per origin, bounded, forgotten when nc runs out" {
  let challenge = (nonce : String, qop : String?) => {
    let params = [("realm", "r"), ("nonce", nonce)]
    if qop is Some(qop) {
      params.push(("qop", qop))
    }
    digest_challenge(params, true).unwrap()
  }
  let state = DigestState::new()
  assert_true(state.next("https://a.test:443", true) is None)
  state.adopt("https://a.test:443", challenge("n1", Some("auth")))
  let counts = [0, 1, 2].map(_ => {
    state.next("https://a.test:443", true).map(next => next.1)
  })
  assert_eq(counts, [Some(2L), Some(3L), Some(4L)])
  assert_true(state.next("https://b.test:443", true) is None, msg="per origin")
  state.adopt("https://a.test:443", challenge("n2", Some("auth")))
  assert_eq(
    state.next("https://a.test:443", true).map(next => (next.0.nonce, next.1)),
    Some(("n2", 2L)),
    msg="a new nonce counts from 1 again",
  )
  state.adopt("https://c.test:443", challenge("n", None))
  assert_true(state.next("https://c.test:443", true) is None, msg="no qop")
  state.adopt("https://d.test:443", challenge("n", Some("auth-int")))
  assert_true(state.next("https://d.test:443", false) is None, msg="no body")
  assert_true(state.next("https://d.test:443", true) is Some(_))
  // Bounded: one origin past the limit forgets the oldest.
  let state = DigestState::new()
  for i in 0..<max_digest_origins {
    state.adopt("https://\{i}.test:443", challenge("n", Some("auth")))
  }
  assert_eq(state.nonces.length(), 16)
  assert_true(state.next("https://0.test:443", true) is Some(_))
  state.adopt("https://new.test:443", challenge("n", Some("auth")))
  assert_eq(state.nonces.length(), 16)
  assert_true(state.next("https://0.test:443", true) is None, msg="oldest")
  assert_true(state.next("https://1.test:443", true) is Some(_))
  assert_true(state.next("https://new.test:443", true) is Some(_))
  // The count ends where nc's eight hex digits do.
  assert_eq(max_nonce_count, 4_294_967_295L)
  assert_eq(next_nonce_count(4_294_967_294L), Some(4_294_967_295L))
  assert_eq(next_nonce_count(4_294_967_295L), None)
  state.nonces.get("https://1.test:443").unwrap().count = max_nonce_count
  assert_true(state.next("https://1.test:443", true) is None)
  assert_true(state.nonces.get("https://1.test:443") is None, msg="forgotten")
}

///|
test "should_answer: once, and once more for a stale nonce" {
  let cases : Array[(Int32, Bool, Bool)] = [
    (0, false, true),
    (0, true, true),
    (1, false, false),
    (1, true, true),
    (2, true, false),
  ]
  for case in cases {
    assert_eq(should_answer(case.0, case.1), case.2, msg=@debug.to_string(case))
  }
}

///|
test "digest_target: the origin and the request target" {
  let cases : Array[(String, (String, String)?)] = [
    (
      "https://a.test/dir/index.html?x=1#frag",
      Some(("https://a.test:443", "/dir/index.html?x=1")),
    ),
    ("http://A.test", Some(("http://a.test:80", "/"))),
    ("http://a.test:8080/p", Some(("http://a.test:8080", "/p"))),
    ("http://[::1]/", Some(("http://[::1]:80", "/"))),
    ("foo://a.test/x", Some(("foo://a.test:", "/x"))),
    ("/relative", None),
    ("http://a.test:99999/", None),
  ]
  for case in cases {
    assert_eq(
      digest_target(case.0).map(target => (target.1, target.2)),
      case.1,
      msg=case.0,
    )
  }
  let url = @model.Url::parse("https://a.test/x")
  assert_true(same_origin_as(url, "https://a.test:443/y"))
  assert_false(same_origin_as(url, "http://a.test/x"))
  assert_false(same_origin_as(url, "https://b.test/x"))
  assert_false(same_origin_as(url, "http://a.test:99999/"))
}

///|
test "hex8 and make_cnonce" {
  assert_eq(hex8(1), "00000001")
  assert_eq(hex8(0xABCDEF01L), "abcdef01")
  assert_eq(make_cnonce(() => 0.5), "80000000800000008000000080000000")
  assert_eq(make_cnonce(() => 1.0), "ffffffffffffffffffffffffffffffff")
  assert_eq(make_cnonce(() => -1.0), "00000000000000000000000000000000")
  assert_eq(ext_value("a b~é"), "a%20b~%C3%A9")
}
