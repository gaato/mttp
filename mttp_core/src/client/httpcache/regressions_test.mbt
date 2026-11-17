///|
priv struct FailingRemovalStore {
  memory : @httpcache.MemoryStore
  lookups : Ref[Int32]
  driver : @driver.Driver
  pause_lookup : Ref[Bool]
  entered : Ref[Bool]
}

///|
impl @httpcache.CacheStore for FailingRemovalStore with fn lookup(self, key) {
  self.lookups.val += 1
  let entries = self.memory.lookup(key)
  if self.pause_lookup.val {
    self.entered.val = true
    self.driver.sleep(20)
  }
  entries
}

///|
fn failing_store(d : @driver.Driver) -> FailingRemovalStore {
  {
    memory: @httpcache.MemoryStore::new(),
    lookups: Ref(0),
    driver: d,
    pause_lookup: Ref(false),
    entered: Ref(false),
  }
}

///|
impl @httpcache.CacheStore for FailingRemovalStore with fn insert(
  self,
  key,
  stored,
) {
  self.memory.insert(key, stored)
}

///|
impl @httpcache.CacheStore for FailingRemovalStore with fn remove(_, _) {
  fail("invalidation failed")
}

///|
test "failed invalidation disables reuse of retained store entries" {
  let d = @driver.Driver::new()
  let version = Ref(b"old")
  let calls = Ref(0)
  let store = failing_store(d)
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((r, _) => {
      calls.val += 1
      if r.meth == Put {
        version.val = b"new"
      }
      response(body=version.val)
    }),
    clock=@sim.FakeClock::new(),
    store~,
  )
  ignore(fetch(d, cache))
  assert_eq(status(fetch(d, cache)), Some(Hit))
  ignore(
    fetch(d, cache, request=@mttp_core.Request::put("http://example.test/a")),
  )
  let lookups = store.lookups.val
  let r = fetch(d, cache)
  assert_eq(r.body.as_bytes(), Some(b"new"))
  assert_eq(status(r), Some(Bypass))
  assert_eq(store.lookups.val, lookups)
  assert_eq(
    fetch(
      d,
      cache,
      request=@mttp_core.Request::get("http://example.test/a").header(
        "cache-control", "only-if-cached",
      ),
    ).status,
    504,
  )
  assert_eq(calls.val, 3)
}

///|
test "empty HTTP paths share lookup and invalidation keys with slash paths" {
  for scheme in ["http", "https"] {
    for
      (stored_suffix, mutation_suffix) in [
        ("", "/"),
        ("/", ""),
        ("?q=1", "/?q=1"),
      ] {
      let d = @driver.Driver::new()
      let version = Ref(b"old")
      let cache = @httpcache.HttpCache::new(
        @client.from_fn((r, _) => {
          if r.meth == Put {
            version.val = b"new"
          }
          response(body=version.val)
        }),
        clock=@sim.FakeClock::new(),
      )
      let origin = scheme + "://example.test"
      let stored = @mttp_core.Request::get(origin + stored_suffix)
      ignore(fetch(d, cache, request=stored))
      ignore(
        fetch(
          d,
          cache,
          request=@mttp_core.Request::put(origin + mutation_suffix),
        ),
      )
      let r = fetch(d, cache, request=stored)
      assert_eq(r.body.as_bytes(), Some(b"new"))
      assert_eq(status(r), Some(Miss))
      assert_eq(
        status(
          fetch(
            d,
            cache,
            request=@mttp_core.Request::get(origin + mutation_suffix),
          ),
        ),
        Some(Hit),
      )
    }
    for field in ["location", "content-location"] {
      let d = @driver.Driver::new()
      let version = Ref(b"old")
      let origin = scheme + "://example.test"
      let cache = @httpcache.HttpCache::new(
        @client.from_fn((r, _) => {
          if r.meth == Put {
            version.val = b"new"
          }
          response(extra=[(field, origin)], body=version.val)
        }),
        clock=@sim.FakeClock::new(),
      )
      ignore(fetch(d, cache, request=@mttp_core.Request::get(origin + "/")))
      ignore(
        fetch(d, cache, request=@mttp_core.Request::put(origin + "/update")),
      )
      assert_eq(
        status(fetch(d, cache, request=@mttp_core.Request::get(origin + "/"))),
        Some(Miss),
      )
    }
  }
}

///|
test "HEAD metadata contradicting a stored GET invalidates its body" {
  for
    (field, old, new) in [
      ("etag", "\"v1\"", "\"v2\""),
      (
        "last-modified", "Thu, 01 Jan 1970 00:00:00 GMT", "Thu, 01 Jan 1970 00:00:01 GMT",
      ),
      ("content-length", "3", "4"),
      ("etag", "\"v1\"", "\"v1\""),
      (
        "last-modified", "Thu, 01 Jan 1970 00:00:00 GMT", "Thu, 01 Jan 1970 00:00:00 GMT",
      ),
      ("content-length", "3", "3"),
      ("x-unrelated", "a", "b"),
    ] {
    let d = @driver.Driver::new()
    let changed = Ref(false)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((r, _) => {
        if r.meth == Head {
          changed.val = old != new
          response(extra=[(field, new)], body=b"")
        } else {
          response(
            extra=[(field, if changed.val { new } else { old })],
            body=if changed.val { b"new!" } else { b"old" },
          )
        }
      }),
      clock=@sim.FakeClock::new(),
    )
    ignore(fetch(d, cache))
    ignore(
      fetch(
        d,
        cache,
        request=@mttp_core.Request::new(Head, "http://example.test/a").header(
          "cache-control", "no-cache",
        ),
      ),
    )
    let r = fetch(d, cache)
    assert_eq(
      r.body.as_bytes(),
      Some(if old != new { b"new!" } else { b"old" }),
    )
    assert_eq(
      status(r),
      Some(if old != new || field == "content-length" { Miss } else { Hit }),
    )
  }
}

///|
test "validating 304 accepts weakly matching entity tags" {
  for
    (stored_tag, validated_tag) in [
      ("\"v1\"", "W/\"v1\""),
      ("W/\"v1\"", "\"v1\""),
      ("W/\"v1\"", "W/\"v1\""),
    ] {
    let d = @driver.Driver::new()
    let calls = Ref(0)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((r, _) => {
        calls.val += 1
        if calls.val == 1 {
          response(cc="max-age=0", extra=[("etag", stored_tag)])
        } else {
          assert_eq(r.headers.get("if-none-match"), Some(stored_tag)) catch {
            e => abort(e.to_string())
          }
          response(status=304, extra=[("etag", validated_tag)], body=b"")
        }
      }),
      clock=@sim.FakeClock::new(),
    )
    ignore(fetch(d, cache))
    let r = fetch(d, cache)
    assert_eq(r.status, 200)
    assert_eq(r.body.as_bytes(), Some(b"body"))
    assert_eq(status(r), Some(Revalidated))
    assert_eq(r.headers.get("etag"), Some(validated_tag))
    assert_eq(status(fetch(d, cache)), Some(Hit))
    assert_eq(calls.val, 2)
  }
}

///|
test "RFC 6585 statuses cannot be stored even with explicit freshness" {
  for status_code in [428, 429, 431, 511] {
    let d = @driver.Driver::new()
    let calls = Ref(0)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        response(status=if calls.val == 1 { status_code } else { 200 })
      }),
      clock=@sim.FakeClock::new(),
    )
    assert_eq(fetch(d, cache).status, status_code)
    let r = fetch(d, cache)
    assert_eq(r.status, 200)
    assert_eq(status(r), Some(Miss))
    assert_eq(status(fetch(d, cache)), Some(Hit))
    assert_eq(calls.val, 2)
  }
}

///|
test "validation recomputes Age without inheriting the previous exchange" {
  for new_age in [None, Some("5")] {
    let d = @driver.Driver::new()
    let calls = Ref(0)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        if calls.val == 1 {
          response(extra=[("etag", "\"v1\""), ("age", "60")])
        } else {
          let fields = [("date", "Thu, 01 Jan 1970 00:00:00 GMT")]
          if new_age is Some(age) {
            fields.push(("age", age))
          }
          response(status=304, extra=fields, body=b"")
        }
      }),
      clock=@sim.FakeClock::new(),
    )
    ignore(fetch(d, cache))
    let r = fetch(d, cache)
    assert_eq(status(r), Some(Revalidated))
    assert_eq(r.headers.get("age"), Some(new_age.unwrap_or("0")))
    assert_eq(status(fetch(d, cache)), Some(Hit))
    assert_eq(calls.val, 2)
  }
}

///|
test "legacy Pragma parses directive lists and all fields case insensitively" {
  for
    (values, force) in [
      (["extension, no-cache"], true),
      (["extension", "No-CaChE"], true),
      (["extension, NO-CACHE, other"], true),
      (["extension=\"no-cache\""], false),
    ] {
    let d = @driver.Driver::new()
    let calls = Ref(0)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        response()
      }),
      clock=@sim.FakeClock::new(),
    )
    ignore(fetch(d, cache))
    let mut request = @mttp_core.Request::get("http://example.test/a")
    for value in values {
      request = request.header("pragma", value)
    }
    assert_eq(
      status(fetch(d, cache, request~)),
      Some(if force { Miss } else { Hit }),
    )
    assert_eq(calls.val, if force { 2 } else { 1 })
    let explicit = request.header("cache-control", "max-age=60")
    assert_eq(status(fetch(d, cache, request=explicit)), Some(Hit))
  }
}

///|
test "failed removal also protects suspended lookups and variant eviction" {
  for eviction in [false, true] {
    let d = @driver.Driver::new()
    let store = failing_store(d)
    let version = Ref(b"old")
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((r, _) => {
        if r.meth == Put {
          version.val = b"new"
        }
        response(extra=[("vary", "x-variant")], body=version.val)
      }),
      clock=@sim.FakeClock::new(),
      store~,
      max_variants=1,
    )
    ignore(fetch(d, cache))
    if eviction {
      // Filling the second selection must stop when removing the first fails.
      ignore(
        fetch(
          d,
          cache,
          request=@mttp_core.Request::get("http://example.test/a").header(
            "x-variant", "second",
          ),
        ),
      )
    } else {
      store.pause_lookup.val = true
      d.run(() => {
        let result : Ref[Bytes?] = Ref(None)
        let reader = d.spawn(() => {
          let r = cache.send(
            @mttp_core.Request::get("http://example.test/a"),
            @mttp_core.SendOptions::default(),
          )
          defer r.close()
          result.val = Some(r.body.read_all(max=10))
        })
        while !store.entered.val {
          d.pause()
        }
        let mutation = cache.send(
          @mttp_core.Request::put("http://example.test/a"),
          @mttp_core.SendOptions::default(),
        )
        mutation.close()
        assert_true(reader.wait())
        assert_eq(result.val, Some(b"new"))
      })
      store.pause_lookup.val = false
    }
    let lookups = store.lookups.val
    assert_eq(status(fetch(d, cache)), Some(Bypass))
    assert_eq(store.lookups.val, lookups)
  }
}
