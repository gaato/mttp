// An unbounded reference keeps quota bounds and Retry-After independently.
// Joining keys appends quota bounds and takes the longest block; neither
// constraint's existence, authority or expiry depends on the other's shape.
// No production reconciliation, alias or decision helper is used by the model.

///|
priv struct ModelBucket {
  caps : Array[(Int32, Int64)]
  mut block : Int64
  mut block_sequence : Int64
  mut restricted : Int64
  mut consumed : Int64
}

///|
fn ModelBucket::left(self : ModelBucket) -> Int32 {
  self.caps.fold(init=2147483647, (n, c) => n.min(c.0))
}

///|
fn ModelBucket::until(self : ModelBucket) -> Int64 {
  self.caps.fold(init=0L, (t, c) => t.max(c.1))
}

///|
priv struct SequenceModel {
  buckets : Map[String, ModelBucket]
  routes : Map[String, (String, Int64)]
}

///|
fn SequenceModel::key(self : SequenceModel, bucket : String) -> String {
  self.routes.get(bucket).map(r => r.0).unwrap_or(bucket)
}

///|
fn SequenceModel::join(
  self : SequenceModel,
  from : String,
  to : String,
) -> Unit {
  if from == to {
    return
  }
  guard self.buckets.get(from) is Some(source) else { return }
  let dest = self.buckets
    .get(to)
    .unwrap_or({
      caps: [],
      block: 0L,
      block_sequence: 0L,
      restricted: 0L,
      consumed: 0L,
    })
  let caps = dest.caps.copy()
  caps.append(source.caps)
  self.buckets[to] = {
    caps,
    block: source.block.max(dest.block),
    block_sequence: source.block_sequence.max(dest.block_sequence),
    restricted: source.restricted.max(dest.restricted),
    consumed: source.consumed.max(dest.consumed),
  }
}

///|
fn SequenceModel::expire(self : SequenceModel, now : Int64) -> Unit {
  let expired = self.buckets
    .keys()
    .filter(k => {
      let b = self.buckets[k]
      if b.until() <= now {
        b.caps.clear()
        b.restricted = 0L
        b.consumed = 0L
      }
      if b.block <= now {
        b.block = 0L
        b.block_sequence = 0L
      }
      b.caps.is_empty() && b.block == 0L
    })
    .to_array()
  for key in expired {
    self.buckets.remove(key)
  }
  let aliases = self.routes
    .keys()
    .filter(k => self.routes[k].1 <= now)
    .to_array()
  for bucket in aliases {
    self.join(self.routes[bucket].0, bucket)
    self.routes.remove(bucket)
  }
}

///|
fn SequenceModel::consume(
  self : SequenceModel,
  admission : @client.Admission,
) -> Unit {
  if self.buckets.get(self.key(admission.bucket())) is Some(b) &&
    !b.caps.is_empty() {
    b.caps.push(((b.left() - 1).max(0), b.until()))
    b.consumed = b.consumed.max(admission.sequence())
  }
}

///|
fn SequenceModel::release(
  self : SequenceModel,
  admission : @client.Admission,
  quota : (Int32, Int64)?,
  retry : Int32?,
  named : String?,
  now : Int64,
) -> Unit {
  self.expire(now)
  let bucket = admission.bucket()
  let key = named.unwrap_or(self.key(bucket))
  self.join(self.key(bucket), key)
  let seq = admission.sequence()
  if quota is Some(_) || retry is Some(_) {
    let b = self.buckets
      .get(key)
      .unwrap_or({
        caps: [],
        block: 0L,
        block_sequence: 0L,
        restricted: 0L,
        consumed: 0L,
      })
    let eligible = seq > b.restricted.max(b.block_sequence) && seq >= b.consumed
    if retry is Some(ms) {
      if eligible {
        b.caps.clear()
        b.restricted = 0L
        b.consumed = 0L
      }
      b.block = b.block.max(now + ms.to_int64())
      b.block_sequence = b.block_sequence.max(seq)
    } else if quota is Some(q) {
      let left = b.left()
      let until = b.until()
      if b.caps.is_empty() {
        if eligible {
          b.caps.push(q)
          b.restricted = seq
        }
      } else {
        if eligible {
          b.caps.clear()
        }
        b.caps.push(q)
        if q.0 < left || (q.0 == 0 && q.1 > until) {
          b.restricted = b.restricted.max(seq)
        }
      }
    }
    self.buckets[key] = b
  }
  if named is Some(key) {
    if key == bucket {
      self.routes.remove(bucket)
    } else {
      self.routes[bucket] = (key, now + 3_600_000L)
    }
  }
}

///|
fn SequenceModel::check(
  self : SequenceModel,
  limiter : WindowLimiter,
  clock : @sim.FakeClock,
  context : String,
) -> Unit raise {
  let now = clock.now_unix_ms()
  self.expire(now)
  for bucket in ["a", "b", "shared"] {
    let state = limiter.states.get(limiter.resolve(bucket, limiter.now()))
    let quota = state.bind(s => s.quota).filter(q => q.until > now)
    let block = state.bind(s => s.block).filter(b => b.until > now)
    let expected = self.buckets.get(self.key(bucket))
    assert_eq(
      quota is Some(_),
      expected is Some(b) && !b.caps.is_empty(),
      msg=context + ": quota presence",
    )
    assert_eq(
      block is Some(_),
      expected is Some(b) && b.block > now,
      msg=context + ": block presence",
    )
    if expected is Some(b) {
      if quota is Some(q) {
        assert_eq(
          q.value.remaining,
          b.left(),
          msg=context + ": quota remaining",
        )
        assert_eq(q.until, b.until(), msg=context + ": quota deadline")
        assert_eq(
          q.restricted_by,
          b.restricted,
          msg=context + ": quota sequence",
        )
        assert_eq(
          q.consumed_by,
          b.consumed,
          msg=context + ": consumption sequence",
        )
      }
      if block is Some(block) {
        assert_eq(block.until, b.block, msg=context + ": block deadline")
        assert_eq(
          block.sequence,
          b.block_sequence,
          msg=context + ": block sequence",
        )
      }
    }
  }
}

///|
test "delivery permutations follow admission sequence with relative and absolute resets" {
  @driver.run_sync(() => {
    for relative in [false, true] {
      for with_quota in [false, true] {
        for
          order in [
            [0, 1, 2],
            [0, 2, 1],
            [1, 0, 2],
            [1, 2, 0],
            [2, 0, 1],
            [2, 1, 0],
          ] {
          let clock = @sim.FakeClock::new()
          let limiter = WindowLimiter::new(
            clock,
            rate_limit_headers(
              remaining="left",
              reset_after_seconds=if relative { "reset" } else { "unused" },
              reset_unix_seconds="reset",
            ),
          )
          let model : SequenceModel = { buckets: Map([]), routes: Map([]), }
          let admissions = Array::makei(3, _ => {
            @client.Admission::new("a", sequence=0L)
          })
          for i in 0..<3 {
            admissions[i] = limiter.acquire("a", global_exempt=false)
          }
          for i in order {
            let now = clock.now_unix_ms()
            let reset = if i == 0 { 1 } else { 60 }
            let left = if i == 0 { 5 } else { 0 }
            let parsed = i != 1 || with_quota
            let headers = if parsed {
              alias_quota("\{left}", "\{reset}")
            } else {
              @mttp_core.Headers::empty()
            }
            let headers = if i == 1 {
              headers.set("retry-after", "1")
            } else {
              headers
            }
            limiter.release(
              admissions[i],
              status=if i == 1 { 429 } else { 200 },
              headers~,
            )
            model.release(
              admissions[i],
              if parsed {
                Some(
                  (
                    left,
                    (if relative { now } else { 0L }) + reset.to_int64() * 1000L,
                  ),
                )
              } else {
                None
              },
              if i == 1 {
                Some(1000)
              } else {
                None
              },
              None,
              now,
            )
            model.check(
              limiter,
              clock,
              "permutation \{Repr(order)} relative=\{relative} quota=\{with_quota}",
            )
            clock.advance(100)
          }
        }
      }
    }
  })
}

///|
test "alias joins preserve independent constraints for every pair of state shapes" {
  @driver.run_sync(() => {
    // 0: quota only, 1: Retry-After only, 2: both. All nine transfer pairs
    // are checked with exhausted/positive quota and lazy/forced block expiry.
    for source in 0..<3 {
      for destination in 0..<3 {
        for left in [0, 2] {
          for sweep in [false, true] {
            let clock = @sim.FakeClock::new()
            let limiter = alias_limiter(clock)
            let model : SequenceModel = { buckets: Map([]), routes: Map([]), }
            let naming = limiter.acquire("a", global_exempt=false)
            let source_block = limiter.acquire("a", global_exempt=false)
            let source_quota = limiter.acquire("a", global_exempt=false)
            let dest_block = limiter.acquire("shared", global_exempt=false)
            let dest_quota = limiter.acquire("shared", global_exempt=false)
            for
              (shape, block, quota, reset, ms) in [
                (source, source_block, source_quota, 60, 1000),
                (destination, dest_block, dest_quota, 90, 2000),
              ] {
              if shape != 0 {
                limiter.release(
                  block,
                  status=429,
                  headers=@mttp_core.Headers::of([("retry-after-ms", "\{ms}")]),
                )
                model.release(block, None, Some(ms), None, 0L)
              } else {
                limiter.release(
                  block,
                  status=0,
                  headers=@mttp_core.Headers::empty(),
                )
              }
              if shape != 1 {
                limiter.release(
                  quota,
                  status=200,
                  headers=alias_quota("\{left}", "\{reset}"),
                )
                model.release(
                  quota,
                  Some((left, reset.to_int64() * 1000L)),
                  None,
                  None,
                  0L,
                )
              } else {
                limiter.release(
                  quota,
                  status=0,
                  headers=@mttp_core.Headers::empty(),
                )
              }
            }
            model.check(limiter, clock, "before shape join")
            limiter.release(
              naming,
              status=200,
              headers=@mttp_core.Headers::of([("key", "shared")]),
            )
            model.release(naming, None, None, Some("shared"), 0L)
            let context = "source=\{source} destination=\{destination} left=\{left} sweep=\{sweep}"
            model.check(limiter, clock, context + ": joined")
            clock.advance(2500)
            if sweep {
              limiter.sweep_states(limiter.now(), force=true)
            }
            model.check(limiter, clock, context + ": block expired")
            let has_quota = source != 1 || destination != 1
            let required = if has_quota && left == 0 {
              (if destination != 1 { 90000 } else { 60000 }) - 2500
            } else {
              0
            }
            let next = limiter.acquire("a", global_exempt=false)
            assert_eq(
              clock.slept(),
              if required > 0 {
                [required]
              } else {
                []
              },
              msg=context,
            )
            model.expire(clock.now_unix_ms())
            model.consume(next)
            model.check(limiter, clock, context + ": admitted")
            limiter.release(next, status=0, headers=@mttp_core.Headers::empty())
            assert_eq(limiter.admissions.length(), 0)
          }
        }
      }
    }
  })
}

///|
test "quota expiry preserves a separately merged longer Retry-After block" {
  @driver.run_sync(() => {
    for sweep in [false, true] {
      let clock = @sim.FakeClock::new()
      let limiter = alias_limiter(clock)
      let model : SequenceModel = { buckets: Map([]), routes: Map([]), }
      let naming = limiter.acquire("a", global_exempt=false)
      let quota = limiter.acquire("a", global_exempt=false)
      let block = limiter.acquire("shared", global_exempt=false)
      limiter.release(quota, status=200, headers=alias_quota("2", "1"))
      model.release(quota, Some((2, 1000L)), None, None, 0L)
      limiter.release(
        block,
        status=429,
        headers=@mttp_core.Headers::of([("retry-after", "60")]),
      )
      model.release(block, None, Some(60000), None, 0L)
      limiter.release(
        naming,
        status=200,
        headers=@mttp_core.Headers::of([("key", "shared")]),
      )
      model.release(naming, None, None, Some("shared"), 0L)
      model.check(limiter, clock, "independent quota before expiry")
      clock.advance(1000)
      if sweep {
        limiter.sweep_states(limiter.now(), force=true)
      }
      model.check(limiter, clock, "independent block after quota expiry")
      let next = limiter.acquire("a", global_exempt=false)
      assert_eq(clock.slept(), [59000])
      limiter.release(next, status=0, headers=@mttp_core.Headers::empty())
    }
  })
}

///|
test "random admission identities aliases resets and duplicate releases match the reference" {
  @driver.run_sync(() => {
    for seed in 1..<=32 {
      let clock = @sim.FakeClock::new()
      let model : SequenceModel = { buckets: Map([]), routes: Map([]), }
      let limiter = alias_limiter(clock)
      let pending : Array[@client.Admission] = []
      let released : Array[@client.Admission] = []
      let names = ["a", "b", "shared"]
      let mut random = seed.reinterpret_as_uint()
      let draw = (n : Int32) => {
        random = random * 1664525U + 1013904223U
        ((random >> 16).reinterpret_as_int() & 65535) % n
      }
      for step in 0..<300 {
        let before = clock.now_unix_ms()
        model.expire(before)
        let op = draw(10)
        if (op < 3 && pending.length() < 32) || pending.is_empty() {
          let bucket = names[draw(3)]
          let required = model.buckets
            .get(model.key(bucket))
            .map(b => {
              if b.left() == 0 {
                b.block.max(b.until())
              } else {
                b.block
              }
            })
            .unwrap_or(before)
          let token = limiter.acquire(bucket, global_exempt=false)
          assert_true(clock.now_unix_ms() >= required)
          model.expire(clock.now_unix_ms())
          model.consume(token)
          pending.push(token)
        } else if op < 7 {
          let token = pending.remove(draw(pending.length()))
          let status = if draw(2) == 0 { 200 } else { 429 }
          let parsed = draw(4) != 0
          let left = draw(8)
          let reset = (before / 1000L + (draw(4) + 1).to_int64()) * 1000L
          let retry = if status == 429 && draw(4) != 0 {
            Some((draw(3) + 1) * 1000)
          } else {
            None
          }
          let named = if draw(3) == 0 { None } else { Some(names[draw(3)]) }
          let headers = if parsed {
            alias_quota("\{left}", "\{reset / 1000L}")
          } else {
            @mttp_core.Headers::empty()
          }
          let headers = if retry is Some(ms) {
            headers.set("retry-after-ms", "\{ms}")
          } else {
            headers
          }
          let headers = if named is Some(key) {
            headers.set("key", key)
          } else {
            headers
          }
          limiter.release(token, status~, headers~)
          model.release(
            token,
            if parsed {
              Some((left, reset))
            } else {
              None
            },
            retry,
            named,
            before,
          )
          released.push(token)
        } else if op == 7 && !released.is_empty() {
          limiter.release(
            released[draw(released.length())],
            status=429,
            headers=alias_quota("0", "999999999")
              .set("retry-after", "3600")
              .set("key", "wrong"),
          )
        } else {
          clock.advance([0, 100, 1000, 3_600_000][draw(4)])
          if op == 9 {
            limiter.sweep_states(limiter.now(), force=true)
          }
        }
        model.check(limiter, clock, "seed=\{seed}, step=\{step}")
        assert_eq(limiter.admissions.length(), pending.length())
      }
      for token in pending {
        limiter.release(token, status=0, headers=@mttp_core.Headers::empty())
      }
      assert_eq(limiter.admissions.length(), 0)
    }
  })
}
