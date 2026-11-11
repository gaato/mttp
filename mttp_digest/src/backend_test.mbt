///|
fn challenge(nonce~ : String = "n", stale~ : Bool = false) -> @mttp.Headers {
  @mttp.Headers::of([
    (
      "www-authenticate",
      "Digest realm=\"r\", nonce=\"\{nonce}\", qop=auth, stale=\{stale}",
    ),
  ])
}

///|
fn wrap(
  inner : &@mttp.Backend,
) -> @mttp_digest.DigestScheme raise @mttp.TransportError {
  @mttp_digest.DigestScheme::new(inner, "u", "p", origin="https://a.test", random=() => {
    0.5
  })
}

///|
test "Digest concurrent same nonce challenges allocate counts without reuse" {
  for warm in [false, true] {
    let driver = @driver.Driver::new()
    let initial : Array[String?] = []
    let answered : Array[String] = []
    let following : Array[String?] = []
    let backend = wrap(
      @client.from_fn((request, _) => {
        let auth = request.headers.get("authorization")
        if request.url == "https://a.test/warm" {
          @mttp.Response::new(
            if auth is None {
              401
            } else {
              200
            },
            headers=challenge(),
          )
        } else if request.url == "https://a.test/after" {
          following.push(auth)
          @mttp.Response::new(200)
        } else if initial.length() < 3 {
          initial.push(auth)
          // All three calls start before any challenge can update the cache.
          driver.sleep(1)
          @mttp.Response::new(401, headers=challenge())
        } else {
          answered.push(auth.unwrap())
          // Keep challenge responses in flight while other calls adopt it.
          driver.pause()
          @mttp.Response::new(200)
        }
      }),
    )
    defer backend.close()
    driver.run(() => {
      if warm {
        backend
        .send(
          @mttp.Request::get("https://a.test/warm"),
          @mttp.SendOptions::default(),
        )
        .close()
      }
      let tasks = [0, 1, 2].map(i => {
        driver.spawn(() => {
          let response = backend.send(
            @mttp.Request::get("https://a.test/concurrent/\{i}"),
            @mttp.SendOptions::default(),
          )
          assert_eq(response.status, 200)
          response.close()
        })
      })
      for task in tasks {
        assert_true(task.wait())
      }
      backend
      .send(
        @mttp.Request::get("https://a.test/after"),
        @mttp.SendOptions::default(),
      )
      .close()
    })
    assert_eq(initial.length(), 3)
    assert_eq(answered.length(), 3)
    let expected = if warm {
      ["00000005", "00000006", "00000007"]
    } else {
      ["00000001", "00000002", "00000003"]
    }
    for i in 0..<3 {
      if warm {
        assert_true(
          initial[i]
          .unwrap()
          .contains("nc=\{["00000002", "00000003", "00000004"][i]}"),
        )
      } else {
        assert_eq(initial[i], None)
      }
      assert_true(answered[i].contains("nc=\{expected[i]}"))
    }
    assert_eq(following.length(), 1)
    let count = if warm { "00000008" } else { "00000004" }
    assert_true(following[0].unwrap().contains("nc=\{count}"))
  }
}

///|
test "Digest new nonce and stale same nonce reset challenge counts" {
  for stale in [false, true] {
    let sent : Array[String?] = []
    let backend = wrap(
      @client.from_fn((request, _) => {
        sent.push(request.headers.get("authorization"))
        match sent.length() {
          1 => @mttp.Response::new(401, headers=challenge())
          3 =>
            @mttp.Response::new(
              401,
              headers=challenge(nonce=if stale { "n" } else { "new" }, stale~),
            )
          _ => @mttp.Response::new(200)
        }
      }),
    )
    defer backend.close()
    @driver.run_sync(() => {
      for _ in 0..<3 {
        let response = backend.send(
          @mttp.Request::get("https://a.test/"),
          @mttp.SendOptions::default(),
        )
        assert_eq(response.status, 200)
        response.close()
      }
    })
    assert_eq(sent.length(), 5)
    assert_eq(sent[0], None)
    for i, count in ["00000001", "00000002", "00000001", "00000002"] {
      assert_true(sent[i + 1].unwrap().contains("nc=\{count}"))
    }
    let nonce = if stale { "n" } else { "new" }
    assert_true(sent[4].unwrap().contains("nonce=\"\{nonce}\""))
  }
}

///|
test "Digest reuses counted nonces and closes each replaced body" {
  let driver = @driver.Driver::new()
  let first_body = @sim.Feed::bytes(driver, [b"unread"])
  let seen : Array[String?] = []
  let closed = Ref(0)
  let inner = @client.from_fn(
    (request, _) => {
      seen.push(request.headers.get("authorization"))
      if seen.length() == 1 {
        @mttp.Response::new(
          401,
          headers=challenge(),
          body=Stream(@mttp.StreamBody::new(first_body)),
        )
      } else {
        @mttp.Response::new(200)
      }
    },
    on_close=() => closed.val += 1,
  )
  let backend = wrap(inner)
  @driver.run_sync(() => {
    for _ in 0..<2 {
      let response = backend.send(
        @mttp.Request::get("https://a.test/p?q=1"),
        @mttp.SendOptions::default(),
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
    let sent : Array[@mttp.Request] = []
    let backend = wrap(
      @client.from_fn((request, _) => {
        sent.push(request)
        @mttp.Response::new(401, headers=challenge(stale~))
      }),
    )
    @driver.run_sync(() => {
      assert_eq(
        backend.send(
          @mttp.Request::get("https://a.test/"),
          @mttp.SendOptions::default(),
        ).status,
        401,
      )
      assert_eq(sent.length(), if stale { 3 } else { 2 })
      let before = sent.length()
      let _ = backend.send(
        @mttp.Request::get("https://b.test/"),
        @mttp.SendOptions::default(),
      )
      assert_eq(sent.length(), before + 1)
      assert_eq(sent[before].headers.get("authorization"), None)
      let _ = backend.send(
        @mttp.Request::get("https://a.test/").header(
          "authorization", "explicit",
        ),
        @mttp.SendOptions::default(),
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
  let upload = @sim.Feed::bytes(driver, [b"body"])
  let sent = Ref(0)
  let backend = wrap(
    @client.from_fn((_, _) => {
      sent.val += 1
      @mttp.Response::new(401, headers=challenge())
    }),
  )
  @driver.run_sync(() => {
    let response = backend.send(
      @mttp.Request::post("https://a.test/").body_stream(upload),
      @mttp.SendOptions::default(),
    )
    response.close()
    assert_eq(sent.val, 1)
  })
  backend.close()
  assert_eq(upload.closes(), 1)
  assert_eq(upload.reads(), 0)
  upload.close()
  for extra in [16384, 16385] {
    let sent = Ref(0)
    let backend = wrap(
      @client.from_fn((_, _) => {
        sent.val += 1
        @mttp.Response::new(
          401,
          headers=challenge().add("www-authenticate", "x".repeat(extra)),
        )
      }),
    )
    @driver.run_sync(() => {
      let response = backend.send(
        @mttp.Request::get("https://a.test/"),
        @mttp.SendOptions::default(),
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
      @mttp.TransportError(..) => ()
      error => raise error
    }
  }
  @driver.run_sync(() => {
    // Factory is nonraising because its fixed origin has already been checked.
    @sim.check_backend_contract(() => {
      wrap(@testing.BackendStub::new()) catch {
        _ => abort("fixed origin")
      }
    })
  })
}

///|
test "Digest does not answer a challenge attributed to another origin" {
  let sent = Ref(0)
  let backend = wrap(
    @client.from_fn((_, _) => {
      sent.val += 1
      let response = @mttp.Response::new(401, headers=challenge())
      {
        ..response,
        attributes: response.attributes.put(
          @client.final_url, "https://b.test/",
        ),
      }
    }),
  )
  @driver.run_sync(() => {
    let response = backend.send(
      @mttp.Request::get("https://a.test/"),
      @mttp.SendOptions::default(),
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
        @mttp.Response::new(
          401,
          headers=@mttp.Headers::of([
            ("x-other", "ignored"),
            ("www-authenticate", base + suffix),
          ]),
        )
      }),
    )
    @driver.run_sync(() => {
      let response = backend.send(
        @mttp.Request::get("https://a.test/"),
        @mttp.SendOptions::default(),
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
      @mttp.Response::new(
        if seen.length() == 1 {
          401
        } else {
          200
        },
        headers=challenge(),
      )
    }),
  )
  @driver.run_sync(() => {
    let request = {
      ..@mttp.Request::get("https://a.test/path"),
      meth: @mttp.Method::Connect,
    }
    let response = backend.send(request, @mttp.SendOptions::default())
    response.close()
  })
  assert_true(seen[1].unwrap().contains("uri=\"a.test:443\""))
  backend.close()
}

///|
test "Digest replaces lone surrogates during hashing and extended username encoding" {
  let seen : Array[String?] = []
  let inner = @client.from_fn((request, _) => {
    seen.push(request.headers.get("authorization"))
    @mttp.Response::new(
      if seen.length() == 1 {
        401
      } else {
        200
      },
      headers=challenge(),
    )
  })
  let lone = String::from_array([(0xd800).unsafe_to_char()])
  let backend = @mttp_digest.DigestScheme::new(
    inner,
    lone,
    lone,
    origin="https://a.test",
    random=() => 0.5,
  )
  @driver.run_sync(() => {
    let response = backend.send(
      @mttp.Request::get("https://a.test/"),
      @mttp.SendOptions::default(),
    )
    assert_eq(response.status, 200)
    response.close()
  })
  assert_true(seen[1].unwrap().contains("username*=UTF-8''%EF%BF%BD"))
  backend.close()
}
