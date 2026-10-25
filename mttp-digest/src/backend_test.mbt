///|
fn challenge(nonce~ : String = "n", stale~ : Bool = false) -> @model.Headers {
  @model.Headers::of([
    (
      "www-authenticate",
      "Digest realm=\"r\", nonce=\"\{nonce}\", qop=auth, stale=\{stale}",
    ),
  ])
}

///|
fn wrap(
  inner : &@client.Backend,
) -> @mttp_digest.DigestScheme raise @model.TransportError {
  @mttp_digest.DigestScheme::new(inner, "u", "p", origin="https://a.test", random=() => {
    0.5
  })
}

///|
test "Digest reuses counted nonces and closes each replaced body" {
  let driver = @driver.Driver::new()
  let first_body = @feed.Feed::bytes(driver, [b"unread"])
  let seen : Array[String?] = []
  let closed = Ref(0)
  let inner = @client.from_fn(
    (request, _) => {
      seen.push(request.headers.get("authorization"))
      if seen.length() == 1 {
        @model.Response::new(
          401,
          headers=challenge(),
          body=Stream(@model.StreamBody::new(first_body)),
        )
      } else {
        @model.Response::new(200)
      }
    },
    on_close=() => closed.val += 1,
  )
  let backend = wrap(inner)
  @testing.run_sync(() => {
    for _ in 0..<2 {
      let response = backend.send(
        @model.Request::get("https://a.test/p?q=1"),
        @client.RequestOptions::default(),
      )
      assert_eq(response.status, 200)
      response.close()
    }
  })
  assert_eq(first_body.closes(), 1)
  assert_eq(first_body.reads(), 0)
  assert_eq(seen.length(), 3)
  assert_eq(seen[0], None)
  assert_true(seen[1].unwrap().contains("nc=00000001"))
  assert_true(seen[1].unwrap().contains("uri=\"/p?q=1\""))
  assert_true(seen[2].unwrap().contains("nc=00000002"))
  backend.close()
  backend.close()
  assert_eq(closed.val, 1)
}

///|
test "Digest stale retry is bounded and origin credentials do not cross hosts" {
  for stale in [false, true] {
    let sent : Array[@model.Request] = []
    let backend = wrap(
      @client.from_fn((request, _) => {
        sent.push(request)
        @model.Response::new(401, headers=challenge(stale~))
      }),
    )
    @testing.run_sync(() => {
      assert_eq(
        backend.send(
          @model.Request::get("https://a.test/"),
          @client.RequestOptions::default(),
        ).status,
        401,
      )
      assert_eq(sent.length(), if stale { 3 } else { 2 })
      let before = sent.length()
      let _ = backend.send(
        @model.Request::get("https://b.test/"),
        @client.RequestOptions::default(),
      )
      assert_eq(sent.length(), before + 1)
      assert_eq(sent[before].headers.get("authorization"), None)
      let _ = backend.send(
        @model.Request::get("https://a.test/").header(
          "authorization", "explicit",
        ),
        @client.RequestOptions::default(),
      )
      assert_eq(sent.length(), before + 2)
      assert_eq(sent[before + 1].headers.get("authorization"), Some("explicit"))
    })
    backend.close()
  }
}

///|
test "Digest refuses oversized challenges and replaying stream bodies" {
  let driver = @driver.Driver::new()
  let upload = @feed.Feed::bytes(driver, [b"body"])
  let sent = Ref(0)
  let backend = wrap(
    @client.from_fn((_, _) => {
      sent.val += 1
      @model.Response::new(401, headers=challenge())
    }),
  )
  @testing.run_sync(() => {
    let response = backend.send(
      @model.Request::post("https://a.test/").body_stream(upload),
      @client.RequestOptions::default(),
    )
    response.close()
    assert_eq(sent.val, 1)
  })
  backend.close()
  upload.close()
  for extra in [16384, 16385] {
    let sent = Ref(0)
    let backend = wrap(
      @client.from_fn((_, _) => {
        sent.val += 1
        @model.Response::new(
          401,
          headers=challenge().add("www-authenticate", "x".repeat(extra)),
        )
      }),
    )
    @testing.run_sync(() => {
      let response = backend.send(
        @model.Request::get("https://a.test/"),
        @client.RequestOptions::default(),
      )
      assert_eq(response.status, 401)
      response.close()
    })
    assert_eq(sent.val, 1)
    backend.close()
  }
}

///|
test "Digest validates credential origins and implements backend contracts" {
  for
    origin in [
      "/relative", "ftp://a.test/", "http://u:p@a.test/", "http://[", "http://a.test/\n",
    ] {
    try {
      let _ = @mttp_digest.DigestScheme::new(
        @testing.BackendStub::new(),
        "u",
        "p",
        origin~,
        random=() => 0.5,
      )
      fail("invalid origin accepted")
    } catch {
      @model.TransportError(..) => ()
      error => raise error
    }
  }
  @testing.run_sync(() => {
    // Factory is nonraising because its fixed origin has already been checked.
    let failures = @testing.check_backend_contract(() => {
      wrap(@testing.BackendStub::new()) catch {
        _ => abort("fixed origin")
      }
    })
    assert_eq(failures, [])
  })
}

///|
test "Digest does not answer a challenge attributed to another origin" {
  let sent = Ref(0)
  let backend = wrap(
    @client.from_fn((_, _) => {
      sent.val += 1
      let response = @model.Response::new(401, headers=challenge())
      {
        ..response,
        attributes: response.attributes.put(
          @client.final_url, "https://b.test/",
        ),
      }
    }),
  )
  @testing.run_sync(() => {
    let response = backend.send(
      @model.Request::get("https://a.test/"),
      @client.RequestOptions::default(),
    )
    assert_eq(response.status, 401)
    response.close()
  })
  assert_eq(sent.val, 1)
  backend.close()
}

///|
test "Digest challenge budget counts UTF8 bytes and includes every field" {
  let base = "Digest realm=r, nonce=n, qop=auth"
  for
    (suffix, expected) in [
      (" ".repeat(16384 - base.length()), 2),
      (" ".repeat(16385 - base.length()), 1),
      ("é".repeat(8192), 1),
    ] {
    let sent = Ref(0)
    let backend = wrap(
      @client.from_fn((_, _) => {
        sent.val += 1
        @model.Response::new(
          401,
          headers=@model.Headers::of([
            ("x-other", "ignored"),
            ("www-authenticate", base + suffix),
          ]),
        )
      }),
    )
    @testing.run_sync(() => {
      let response = backend.send(
        @model.Request::get("https://a.test/"),
        @client.RequestOptions::default(),
      )
      response.close()
    })
    assert_eq(sent.val, expected)
    backend.close()
  }
}

///|
test "Digest CONNECT authenticates the authority request target" {
  let seen : Array[String?] = []
  let backend = wrap(
    @client.from_fn((request, _) => {
      seen.push(request.headers.get("authorization"))
      @model.Response::new(
        if seen.length() == 1 {
          401
        } else {
          200
        },
        headers=challenge(),
      )
    }),
  )
  @testing.run_sync(() => {
    let request = {
      ..@model.Request::get("https://a.test/path"),
      meth: @model.Method::Connect,
    }
    let response = backend.send(request, @client.RequestOptions::default())
    response.close()
  })
  assert_true(seen[1].unwrap().contains("uri=\"a.test:443\""))
  backend.close()
}
