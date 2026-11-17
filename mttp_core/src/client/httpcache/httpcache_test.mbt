///|
fn response(
  cc~ : String = "max-age=60",
  status~ : Int32 = 200,
  extra~ : Array[(String, String)] = [],
  body~ : Bytes = b"body",
) -> @mttp_core.Response {
  @mttp_core.Response::new(
    status,
    headers=@mttp_core.Headers::of(extra).set("cache-control", cc),
    body=Bytes(body),
  )
}

///|
fn fetch(
  d : @driver.Driver,
  cache : @httpcache.HttpCache,
  request~ : @mttp_core.Request = @mttp_core.Request::get(
    "http://example.test/a",
  ),
) -> @mttp_core.Response raise {
  d.run(() => {
    let r = cache.send(request, @mttp_core.SendOptions::default())
    defer r.close()
    let bytes = r.body.read_all(max=2000000)
    { ..r, body: Bytes(bytes), }
  })
}

///|
fn status(r : @mttp_core.Response) -> @httpcache.CacheStatus? {
  r.attributes.get(@httpcache.cache_status)
}

///|
test "fresh hit, Age, HEAD, request directives and metadata" {
  let d = @driver.Driver::new()
  let clock = @sim.FakeClock::new()
  let calls = Ref(0)
  let marker : @mttp_core.AttributeKey[Int32] = @mttp_core.AttributeKey::new(
    "marker",
  )
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      {
        ..response(),
        attributes: @mttp_core.Attributes::empty().put(marker, 42),
      }
    }),
    clock~,
  )
  assert_eq(fetch(d, cache).attributes.get(marker), Some(42))
  clock.advance(2000)
  let hit = fetch(d, cache)
  assert_eq(status(hit), Some(Hit))
  assert_eq(hit.headers.get("age"), Some("2"))
  assert_eq(hit.body.as_bytes(), Some(b"body"))
  assert_eq(
    fetch(
      d,
      cache,
      request=@mttp_core.Request::new(Head, "http://example.test/a"),
    ).body.as_bytes(),
    Some(b""),
  )
  assert_eq(calls.val, 1)
  for directive in ["no-cache", "max-age=0", "min-fresh=60"] {
    clock.advance(1000)
    assert_eq(
      status(
        fetch(
          d,
          cache,
          request=@mttp_core.Request::get("http://example.test/a").header(
            "cache-control", directive,
          ),
        ),
      ),
      Some(Miss),
    )
  }
  assert_eq(calls.val, 4)
}

///|
test "heuristic uses Last-Modified, excludes query, and can be disabled" {
  for
    (url, percent, expected) in [
      ("http://example.test/a", 10, @httpcache.Hit),
      ("http://example.test/a?q", 10, @httpcache.Miss),
      ("http://example.test/a", 0, @httpcache.Miss),
    ] {
    let d = @driver.Driver::new()
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => {
        @mttp_core.Response::new(
          200,
          headers=@mttp_core.Headers::of([
            ("date", "Sun, 06 Nov 1994 08:49:37 GMT"),
            ("last-modified", "Sun, 06 Nov 1994 08:39:37 GMT"),
          ]),
          body=Bytes(b"ok"),
        )
      }),
      clock=@sim.FakeClock::new(start_unix_ms=784111777000L),
      heuristic_percent=percent,
    )
    ignore(fetch(d, cache, request=@mttp_core.Request::get(url)))
    assert_eq(
      status(fetch(d, cache, request=@mttp_core.Request::get(url))),
      Some(expected),
    )
  }
}

///|
test "Vary selects values and distinguishes absent from empty" {
  let d = @driver.Driver::new()
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((r, _) => {
      response(
        extra=[("vary", "Accept-Language")],
        body=@mttp_core.encode_utf8(
          r.headers.get("accept-language").unwrap_or("absent"),
        ),
      )
    }),
    clock=@sim.FakeClock::new(),
  )
  for value in [None, Some(""), Some("ja")] {
    let request = @mttp_core.Request::get("http://example.test/a")
    let request = match value {
      Some(v) => request.header("accept-language", v)
      None => request
    }
    assert_eq(status(fetch(d, cache, request~)), Some(Miss))
    assert_eq(status(fetch(d, cache, request~)), Some(Hit))
  }
}

///|
test "304 merges fields and repeated fields, retains body and extends freshness" {
  for validator in ["etag", "last-modified"] {
    let d = @driver.Driver::new()
    let clock = @sim.FakeClock::new()
    let calls = Ref(0)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((r, _) => {
        calls.val += 1
        if calls.val == 1 {
          response(cc="max-age=0", extra=[
            (validator, "value"),
            ("x-old", "keep"),
            ("x-new", "old"),
          ])
        } else {
          assert_eq(
            r.headers.get(
              if validator == "etag" {
                "if-none-match"
              } else {
                "if-modified-since"
              },
            ),
            Some("value"),
          ) catch {
            e => abort(e.to_string())
          }
          response(
            status=304,
            extra=[
              ("x-new", "a"),
              ("x-new", "b"),
              ("connection", "x-hop"),
              ("x-hop", "drop"),
              ("date", "Thu, 01 Jan 1970 00:00:00 GMT"),
              ("content-length", "999"),
            ],
            body=b"",
          )
        }
      }),
      clock~,
    )
    ignore(fetch(d, cache))
    let r = fetch(d, cache)
    assert_eq(status(r), Some(Revalidated))
    assert_eq(r.body.as_bytes(), Some(b"body"))
    assert_eq(r.headers.get_all("x-new"), ["a", "b"])
    assert_eq(r.headers.get("x-old"), Some("keep"))
    assert_false(r.headers.contains("x-hop"))
    assert_false(r.headers.contains("content-length"))
    assert_eq(status(fetch(d, cache)), Some(Hit))
    assert_eq(calls.val, 2)
  }
}

///|
test "revalidation 200 replaces old representation" {
  let d = @driver.Driver::new()
  let calls = Ref(0)
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      if calls.val == 1 {
        response(cc="max-age=0", extra=[("etag", "old")])
      } else {
        response(body=b"new")
      }
    }),
    clock=@sim.FakeClock::new(),
  )
  ignore(fetch(d, cache))
  assert_eq(fetch(d, cache).body.as_bytes(), Some(b"new"))
  assert_eq(status(fetch(d, cache)), Some(Hit))
  assert_eq(calls.val, 2)
}

///|
test "stale-if-error covers 503 and transport error but respects must-revalidate" {
  for transport in [false, true] {
    for forbid in [false, true] {
      let d = @driver.Driver::new()
      let clock = @sim.FakeClock::new()
      let calls = Ref(0)
      let cache = @httpcache.HttpCache::new(
        @client.from_fn((_, _) => {
          calls.val += 1
          if calls.val == 1 {
            return response(
              cc=if forbid {
                "max-age=0, stale-if-error=10, must-revalidate"
              } else {
                "max-age=0, stale-if-error=10"
              },
            )
          }
          if transport {
            raise @mttp_core.TransportError(
              kind=Network,
              phase=Head,
              detail="offline",
            )
          }
          response(status=503)
        }),
        clock~,
      )
      ignore(fetch(d, cache))
      clock.advance(1000)
      if forbid && transport {
        let failed = try {
          ignore(fetch(d, cache))
          false
        } catch {
          @mttp_core.TransportError(..) => true
          _ => false
        }
        assert_true(failed)
      } else {
        let r = fetch(d, cache)
        assert_eq(r.status, if forbid { 503 } else { 200 })
        assert_eq(status(r), Some(if forbid { Miss } else { Stale }))
      }
    }
  }
}

///|
test "only-if-cached never sends; max-stale permits bounded stale reuse" {
  let d = @driver.Driver::new()
  let clock = @sim.FakeClock::new()
  let calls = Ref(0)
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      response(cc="max-age=0")
    }),
    clock~,
  )
  let request = @mttp_core.Request::get("http://example.test/a").header(
    "cache-control", "only-if-cached",
  )
  assert_eq(fetch(d, cache, request~).status, 504)
  assert_eq(calls.val, 0)
  ignore(fetch(d, cache))
  clock.advance(1000)
  assert_eq(fetch(d, cache, request~).status, 504)
  assert_eq(
    status(
      fetch(
        d,
        cache,
        request=request.set_header(
          "cache-control", "only-if-cached, max-stale=2",
        ),
      ),
    ),
    Some(Stale),
  )
  clock.advance(2000)
  assert_eq(
    fetch(
      d,
      cache,
      request=request.set_header("cache-control", "only-if-cached, max-stale=2"),
    ).status,
    504,
  )
  assert_eq(calls.val, 1)
}

///|
test "Authorization partitions and Bypass skips reads and writes" {
  for mode in [@httpcache.Partition, @httpcache.Bypass] {
    let d = @driver.Driver::new()
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((r, _) => {
        response(
          body=@mttp_core.encode_utf8(
            r.headers.get("authorization").unwrap_or("anonymous"),
          ),
        )
      }),
      clock=@sim.FakeClock::new(),
      credentials=mode,
    )
    for token in ["a", "b"] {
      let request = @mttp_core.Request::get("http://example.test/a").bearer(
        token,
      )
      assert_eq(
        status(fetch(d, cache, request~)),
        Some(if mode == @httpcache.Partition { Miss } else { Bypass }),
      )
      let r = fetch(d, cache, request~)
      assert_eq(
        status(r),
        Some(if mode == @httpcache.Partition { Hit } else { Bypass }),
      )
      assert_eq(
        r.body.as_bytes(),
        Some(@mttp_core.encode_utf8("Bearer " + token)),
      )
    }
    assert_eq(status(fetch(d, cache)), Some(Miss))
  }
}

///|
test "unsafe success invalidates target and same-origin locations only" {
  let d = @driver.Driver::new()
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => {
      response(extra=[
        ("location", "/b"),
        ("content-location", "http://other.test/c"),
      ])
    }),
    clock=@sim.FakeClock::new(),
  )
  for
    url in [
      "http://example.test/a", "http://example.test/b", "http://other.test/c",
    ] {
    ignore(fetch(d, cache, request=@mttp_core.Request::get(url)))
  }
  ignore(
    fetch(d, cache, request=@mttp_core.Request::put("http://example.test/a")),
  )
  for url in ["http://example.test/a", "http://example.test/b"] {
    assert_eq(
      status(fetch(d, cache, request=@mttp_core.Request::get(url))),
      Some(Miss),
    )
  }
  assert_eq(
    status(
      fetch(d, cache, request=@mttp_core.Request::get("http://other.test/c")),
    ),
    Some(Hit),
  )
}

///|
test "Range, no-store, Vary star, 206 and uncacheable status never store" {
  for
    (status_code, extra, request_extra) in [
      (200, [("vary", "*")], []),
      (200, [("cache-control", "no-store")], []),
      (206, [], []),
      (599, [], []),
      (200, [], [("range", "bytes=0-1")]),
      (200, [], [("cache-control", "no-store")]),
    ] {
    let d = @driver.Driver::new()
    let calls = Ref(0)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        @mttp_core.Response::new(
          status_code,
          headers=@mttp_core.Headers::of([("cache-control", "max-age=60")])
            .add("x-test", "yes")
            .add("vary", "x-variant")
            .iter()
            .fold(init=@mttp_core.Headers::of(extra), (h, p) => h.add(p.0, p.1)),
          body=Bytes(b"ok"),
        )
      }),
      clock=@sim.FakeClock::new(),
    )
    let request = {
      ..@mttp_core.Request::get("http://example.test/a"),
      headers: @mttp_core.Headers::of(request_extra),
    }
    ignore(fetch(d, cache, request~))
    ignore(fetch(d, cache, request~))
    assert_eq(calls.val, 2)
  }
  let d = @driver.Driver::new()
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => @mttp_core.Response::new(302)),
    clock=@sim.FakeClock::new(),
  )
  ignore(fetch(d, cache))
  assert_eq(status(fetch(d, cache)), Some(Miss))
}

///|
test "caller conditional is forwarded unchanged" {
  let d = @driver.Driver::new()
  let seen = []
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((r, _) => {
      seen.push(r.headers.get("if-none-match"))
      response(extra=[("etag", "cache")])
    }),
    clock=@sim.FakeClock::new(),
  )
  ignore(fetch(d, cache))
  assert_eq(
    status(
      fetch(
        d,
        cache,
        request=@mttp_core.Request::get("http://example.test/a").header(
          "if-none-match", "caller",
        ),
      ),
    ),
    Some(Bypass),
  )
  assert_eq(seen, [None, Some("caller")])
}

///|
test "abandoned body is not stored; EOF commits; entry bytes bound" {
  for
    (limit, abandon, expected) in [
      (4, false, @httpcache.Hit),
      (3, false, @httpcache.Miss),
      (4, true, @httpcache.Miss),
    ] {
    let d = @driver.Driver::new()
    let feeds = []
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => {
        let feed = @sim.Feed::bytes(d, [b"bo", b"dy"])
        feeds.push(feed)
        { ..response(), body: Stream(@mttp_core.StreamBody::new(feed)), }
      }),
      clock=@sim.FakeClock::new(),
      max_entry_bytes=limit,
    )
    if abandon {
      d.run(() => {
        let r = cache.send(
          @mttp_core.Request::get("http://example.test/a"),
          @mttp_core.SendOptions::default(),
        )
        guard r.body is Stream(s) else { fail("expected stream") }
        ignore(s.take().read_some())
        r.close()
      })
    } else {
      ignore(fetch(d, cache))
    }
    assert_eq(status(fetch(d, cache)), Some(expected))
    assert_eq(feeds[0].closes(), 1)
  }
}

///|
test "LRU entry and total byte bounds evict past capacity" {
  for bytes in [false, true] {
    let d = @driver.Driver::new()
    let store = @httpcache.MemoryStore::new(
      max_entries=if bytes { 10 } else { 2 },
      max_bytes=if bytes { 130L } else { 10000L },
    )
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => response()),
      clock=@sim.FakeClock::new(),
      store~,
    )
    for name in ["a", "b"] {
      ignore(
        fetch(
          d,
          cache,
          request=@mttp_core.Request::get("http://example.test/" + name),
        ),
      )
    }
    // If the byte budget holds only one entry, a has already been evicted.
    if bytes {
      assert_eq(status(fetch(d, cache)), Some(Miss))
    } else {
      assert_eq(status(fetch(d, cache)), Some(Hit))
      ignore(
        fetch(
          d,
          cache,
          request=@mttp_core.Request::get("http://example.test/c"),
        ),
      )
      assert_eq(
        status(
          fetch(
            d,
            cache,
            request=@mttp_core.Request::get("http://example.test/b"),
          ),
        ),
        Some(Miss),
      )
    }
  }
}

///|
test "variants bound evicts oldest selection" {
  let d = @driver.Driver::new()
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => response(extra=[("vary", "x-v")])),
    clock=@sim.FakeClock::new(),
    max_variants=2,
  )
  for value in ["a", "b", "c"] {
    ignore(
      fetch(
        d,
        cache,
        request=@mttp_core.Request::get("http://example.test/a").header(
          "x-v", value,
        ),
      ),
    )
  }
  assert_eq(
    status(
      fetch(
        d,
        cache,
        request=@mttp_core.Request::get("http://example.test/a").header(
          "x-v", "c",
        ),
      ),
    ),
    Some(Hit),
  )
  assert_eq(
    status(
      fetch(
        d,
        cache,
        request=@mttp_core.Request::get("http://example.test/a").header(
          "x-v", "a",
        ),
      ),
    ),
    Some(Miss),
  )
}

///|
test "HTTP cache keeps the Backend contract" {
  @driver.run_sync(() => {
    let wrap = (inner : &@mttp_core.Backend) => {
      @httpcache.HttpCache::new(inner, clock=@sim.FakeClock::new())
    }
    @sim.check_backend_contract(
      () => wrap(@client.from_fn((_, _) => response())),
      wrap=inner => wrap(inner),
    )
  })
}

///|
test "in-flight body cannot resurrect an invalidated representation" {
  let d = @driver.Driver::new()
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => response()),
    clock=@sim.FakeClock::new(),
  )
  let pending = d.run(() => {
    cache.send(
      @mttp_core.Request::get("http://example.test/a"),
      @mttp_core.SendOptions::default(),
    )
  })
  ignore(
    fetch(d, cache, request=@mttp_core.Request::post("http://example.test/a")),
  )
  ignore(d.run(() => pending.body.read_all(max=10)))
  pending.close()
  assert_eq(status(fetch(d, cache)), Some(Miss))
}

///|
test "read error and cancellation never commit and close the source" {
  for cancel in [false, true] {
    let d = @driver.Driver::new()
    let feed = @sim.Feed::new(
      d,
      if cancel {
        [Chunk(b"a"), Wait(1000), End]
      } else {
        [
          Chunk(b"a"),
          Fail(
            @mttp_core.TransportError(kind=Network, phase=Body, detail="broken"),
          ),
        ]
      },
    )
    let calls = Ref(0)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        if calls.val == 1 {
          { ..response(), body: Stream(@mttp_core.StreamBody::new(feed)), }
        } else {
          response()
        }
      }),
      clock=@sim.FakeClock::new(),
    )
    d.run(() => {
      let r = cache.send(
        @mttp_core.Request::get("http://example.test/a"),
        @mttp_core.SendOptions::default(),
      )
      if cancel {
        let task = d.spawn(() => {
          ignore(r.body.read_all(max=10)) catch {
            _ => ()
          }
        })
        d.sleep(1)
        task.cancel()
        assert_false(task.wait())
      } else {
        let failed = try {
          ignore(r.body.read_all(max=10))
          false
        } catch {
          _ => true
        }
        assert_true(failed)
      }
      r.close()
    })
    assert_eq(feed.closes(), 1)
    assert_eq(status(fetch(d, cache)), Some(Miss))
  }
}

///|
test "Pragma forces validation and request no-cache forbids stale-if-error" {
  let d = @driver.Driver::new()
  let clock = @sim.FakeClock::new()
  let calls = Ref(0)
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      if calls.val == 1 {
        response(cc="max-age=0, stale-if-error=60")
      } else {
        response(status=503)
      }
    }),
    clock~,
  )
  ignore(fetch(d, cache))
  for (name, value) in [("pragma", "no-cache"), ("cache-control", "no-cache")] {
    assert_eq(
      fetch(
        d,
        cache,
        request=@mttp_core.Request::get("http://example.test/a").header(
          name, value,
        ),
      ).status,
      503,
    )
  }
}

///|
test "304 Vary update and mismatched entity tag" {
  for mismatch in [false, true] {
    let d = @driver.Driver::new()
    let calls = Ref(0)
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        if calls.val == 1 {
          response(cc="max-age=0", extra=[("etag", "old")])
        } else {
          response(
            status=304,
            extra=[
              ("etag", if mismatch { "other" } else { "old" }),
              ("vary", "x-new"),
            ],
            body=b"",
          )
        }
      }),
      clock=@sim.FakeClock::new(),
    )
    ignore(fetch(d, cache))
    let r = fetch(d, cache)
    assert_eq(status(r), Some(if mismatch { Miss } else { Revalidated }))
    if !mismatch {
      assert_eq(status(fetch(d, cache)), Some(Hit))
      assert_eq(
        status(
          fetch(
            d,
            cache,
            request=@mttp_core.Request::get("http://example.test/a").header(
              "x-new", "v",
            ),
          ),
        ),
        Some(Miss),
      )
    }
  }
}

///|
test "disabled stores, zero variants and zero body bound" {
  for mode in 0..<4 {
    let d = @driver.Driver::new()
    let store = @httpcache.MemoryStore::new(
      max_entries=if mode == 0 { 0 } else { 1024 },
      max_bytes=if mode == 1 { 0L } else { 16777216L },
    )
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => response()),
      clock=@sim.FakeClock::new(),
      store~,
      max_variants=if mode == 2 { 0 } else { 8 },
      max_entry_bytes=if mode == 3 { 0 } else { 1048576 },
    )
    ignore(fetch(d, cache))
    assert_eq(status(fetch(d, cache)), Some(Miss))
  }
}

///|
priv struct BrokenStore {}

///|
impl @httpcache.CacheStore for BrokenStore with fn lookup(_, _) {
  fail("unavailable")
}

///|
impl @httpcache.CacheStore for BrokenStore with fn insert(_, _, _) {
  fail("unavailable")
}

///|
impl @httpcache.CacheStore for BrokenStore with fn remove(_, _) {
  fail("unavailable")
}

///|
test "injected store failures do not fail transport and SendOptions pass through" {
  let d = @driver.Driver::new()
  let options : @mttp_core.SendOptions = {
    timeout_ms: Some(17),
    body: Stream(idle_ms=Some(9)),
  }
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, o) => {
      assert_eq(o, options) catch {
        e => abort(e.to_string())
      }
      response()
    }),
    clock=@sim.FakeClock::new(),
    store=BrokenStore::{ },
  )
  d.run(() => {
    for meth in [@mttp_core.Get, @mttp_core.Put] {
      let r = cache.send(
        @mttp_core.Request::new(meth, "http://example.test/a"),
        options,
      )
      assert_eq(r.status, 200)
      ignore(r.body.read_all(max=10))
      r.close()
    }
  })
}

///|
priv struct SlowStore {
  memory : @httpcache.MemoryStore
  driver : @driver.Driver
  entered : Ref[Bool]
}

///|
impl @httpcache.CacheStore for SlowStore with fn lookup(self, key) {
  self.memory.lookup(key)
}

///|
impl @httpcache.CacheStore for SlowStore with fn insert(self, key, stored) {
  self.entered.val = true
  self.driver.sleep(20)
  self.memory.insert(key, stored)
}

///|
impl @httpcache.CacheStore for SlowStore with fn remove(self, key) {
  self.memory.remove(key)
}

///|
test "suspending store offers are bounded and cannot survive invalidation or close" {
  for close in [false, true] {
    let d = @driver.Driver::new()
    let store = SlowStore::{
      memory: @httpcache.MemoryStore::new(),
      driver: d,
      entered: Ref(false),
    }
    let cache = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => response()),
      clock=@sim.FakeClock::new(),
      store~,
    )
    d.run(() => {
      let r = cache.send(
        @mttp_core.Request::get("http://example.test/a"),
        @mttp_core.SendOptions::default(),
      )
      let task = d.spawn(() => {
        ignore(r.body.read_all(max=10))
        r.close()
      })
      while !store.entered.val {
        d.sleep(1)
      }
      // A concurrent offer is skipped while insertion is suspended.
      let other = cache.send(
        @mttp_core.Request::get("http://example.test/b"),
        @mttp_core.SendOptions::default(),
      )
      ignore(other.body.read_all(max=10))
      other.close()
      if close {
        cache.close()
      } else {
        let changed = cache.send(
          @mttp_core.Request::post("http://example.test/a"),
          @mttp_core.SendOptions::default(),
        )
        changed.close()
      }
      assert_true(task.wait())
    })
    let next = @httpcache.HttpCache::new(
      @client.from_fn((_, _) => response()),
      clock=@sim.FakeClock::new(),
      store~,
    )
    assert_eq(status(fetch(d, next)), Some(Miss))
    assert_eq(
      status(
        fetch(d, next, request=@mttp_core.Request::get("http://example.test/b")),
      ),
      Some(Miss),
    )
  }
}

///|
test "failed unsafe response preserves cache and both same-origin location fields invalidate" {
  let d = @driver.Driver::new()
  let fail_unsafe = Ref(true)
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((r, _) => {
      if r.meth == Put && fail_unsafe.val {
        response(status=400)
      } else {
        response(extra=[("location", "/b"), ("content-location", "/c")])
      }
    }),
    clock=@sim.FakeClock::new(),
  )
  for suffix in ["a", "b", "c"] {
    ignore(
      fetch(
        d,
        cache,
        request=@mttp_core.Request::get("http://example.test/" + suffix),
      ),
    )
  }
  ignore(
    fetch(d, cache, request=@mttp_core.Request::put("http://example.test/a")),
  )
  assert_eq(status(fetch(d, cache)), Some(Hit))
  fail_unsafe.val = false
  ignore(
    fetch(d, cache, request=@mttp_core.Request::put("http://example.test/a")),
  )
  for suffix in ["a", "b", "c"] {
    assert_eq(
      status(
        fetch(
          d,
          cache,
          request=@mttp_core.Request::get("http://example.test/" + suffix),
        ),
      ),
      Some(Miss),
    )
  }
}

///|
test "malformed URL bypass, only-if-cached bypass, and sticky body EOF" {
  let d = @driver.Driver::new()
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => response()),
    clock=@sim.FakeClock::new(),
  )
  assert_eq(
    status(fetch(d, cache, request=@mttp_core.Request::get("http://["))),
    Some(Bypass),
  )
  let offline = fetch(
    d,
    cache,
    request=@mttp_core.Request::get("http://example.test/a")
      .header("range", "bytes=0-1")
      .header("cache-control", "only-if-cached"),
  )
  assert_eq(offline.status, 504)
  assert_eq(status(offline), Some(Bypass))
  d.run(() => {
    let r = cache.send(
      @mttp_core.Request::get("http://example.test/a"),
      @mttp_core.SendOptions::default(),
    )
    guard r.body is Stream(body) else { fail("expected collecting stream") }
    let stream = body.take()
    @sim.check_body_stream_contract(() => stream, b"body")
    r.close()
  })
}

///|
test "a consumed upstream body is refused and closed during handoff" {
  let d = @driver.Driver::new()
  let feed = @sim.Feed::bytes(d, [b"body"])
  let taken = @mttp_core.StreamBody::new(feed)
  ignore(taken.take())
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => { ..response(), body: Stream(taken), }),
    clock=@sim.FakeClock::new(),
  )
  let refused = try {
    ignore(fetch(d, cache))
    false
  } catch {
    @mttp_core.TransportError(..) => true
    _ => false
  }
  assert_true(refused)
  assert_eq(feed.closes(), 1)
}

///|
test "authenticated mutation invalidates anonymous and other credential partitions" {
  let d = @driver.Driver::new()
  let cache = @httpcache.HttpCache::new(
    @client.from_fn((_, _) => response()),
    clock=@sim.FakeClock::new(),
  )
  for credential in [None, Some("a"), Some("b")] {
    let request = @mttp_core.Request::get("http://example.test/a")
    let request = match credential {
      Some(c) => request.bearer(c)
      None => request
    }
    ignore(fetch(d, cache, request~))
    assert_eq(status(fetch(d, cache, request~)), Some(Hit))
  }
  ignore(
    fetch(
      d,
      cache,
      request=@mttp_core.Request::put("http://example.test/a").bearer("a"),
    ),
  )
  for credential in [None, Some("a"), Some("b")] {
    let request = @mttp_core.Request::get("http://example.test/a")
    let request = match credential {
      Some(c) => request.bearer(c)
      None => request
    }
    assert_eq(status(fetch(d, cache, request~)), Some(Miss))
  }
}
