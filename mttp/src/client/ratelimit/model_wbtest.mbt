// An intentionally unbounded reference ledger: keep every quota observation
// and copy the history on key transitions. Queries select the newest window,
// its smallest quota and its Retry-After deadline, plus every active block.
// It omits admission debt, so its quota is an upper bound, not an exact count.
// No production reconciliation, sweep or decision helper is used by the model.

///|
priv struct Observation {
  window : Int64
  remaining : Int32
  until : Int64
  retry : Bool
  block : Int64
}

///|
priv struct Reference {
  history : Map[String, Array[Observation]]
  routes : Map[String, (String, Int64)]
}

///|
fn Reference::view(self : Reference, key : String) -> Observation? {
  guard self.history.get(key) is Some(events) && !events.is_empty() else {
    return None
  }
  let window = events.fold(init=0L, (w, e) => w.max(e.window))
  let latest = events.filter(e => e.window == window)
  let retry = latest.any(e => e.retry)
  Some({
    window,
    remaining: latest.fold(init=2147483647, (n, e) => n.min(e.remaining)),
    until: latest
    .filter(e => e.retry == retry)
    .fold(init=0L, (t, e) => t.max(e.until)),
    retry,
    block: events.fold(init=0L, (t, e) => t.max(e.block)),
  })
}

///|
fn Reference::copy(self : Reference, from : String, to : String) -> Unit {
  if from != to && self.history.get(from) is Some(events) {
    let merged = self.history.get(to).unwrap_or([]).copy()
    merged.append(events)
    self.history[to] = merged
  }
}

///|
fn Reference::expire(self : Reference, now : Int64) -> Unit {
  let expired = self.history
    .keys()
    .filter(key => self.view(key) is Some(v) && v.until <= now && v.block <= now)
    .to_array()
  for key in expired {
    self.history.remove(key)
  }
  let detached = self.routes
    .keys()
    .filter(bucket => self.routes[bucket].1 <= now)
    .to_array()
  for bucket in detached {
    self.copy(self.routes[bucket].0, bucket)
    self.routes.remove(bucket)
  }
}

///|
fn Reference::key(self : Reference, bucket : String) -> String {
  self.routes.get(bucket).map(r => r.0).unwrap_or(bucket)
}

///|
fn Reference::release(
  self : Reference,
  bucket : String,
  named : String?,
  event : Observation?,
  now : Int64,
) -> Unit {
  self.expire(now)
  let key = named.unwrap_or(self.key(bucket))
  self.copy(self.key(bucket), key)
  if event is Some(event) {
    let events = self.history.get(key).unwrap_or([])
    events.push(event)
    self.history[key] = events
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
fn Reference::consume(self : Reference, bucket : String) -> Unit {
  let key = self.key(bucket)
  if self.view(key) is Some(view) && self.history.get(key) is Some(events) {
    self.history[key] = events.map(e => {
      if e.window == view.window {
        { ..e, remaining: (e.remaining - 1).max(0), }
      } else {
        e
      }
    })
  }
}

///|
test "random alias interleavings preserve reference blocks and quota bounds" {
  @driver.run_sync(() => {
    for seed in 1..<=32 {
      let clock = @sim.FakeClock::new()
      let limiter = alias_limiter(clock)
      let model : Reference = { history: Map([]), routes: Map([]), }
      let buckets = ["a", "b", "shared"]
      let pending : Map[String, Int32] = Map([])
      let mut random = seed.reinterpret_as_uint()
      let draw = (n : Int32) => {
        random = random * 1664525U + 1013904223U
        ((random >> 16).reinterpret_as_int() & 65535) % n
      }
      for step in 0..<300 {
        let bucket = buckets[draw(buckets.length())]
        let operation = draw(10)
        let before = clock.now_unix_ms()
        model.expire(before)
        if operation < 3 ||
          (operation < 7 && pending.get(bucket).unwrap_or(0) == 0) {
          let required = match model.view(model.key(bucket)) {
            Some(v) =>
              if v.remaining == 0 {
                v.block.max(v.until)
              } else {
                v.block
              }
            None => before
          }
          limiter.acquire(bucket, global_exempt=false)
          let now = clock.now_unix_ms()
          assert_true(
            now >= required,
            msg="early acquire: seed=\{seed}, step=\{step}",
          )
          model.expire(now)
          model.consume(bucket)
          pending[bucket] = pending.get(bucket).unwrap_or(0) + 1
        } else if operation < 7 {
          let status = if draw(2) == 0 { 200 } else { 429 }
          let parsed = draw(4) != 0
          let old_key = model.key(bucket)
          let old = limiter.states.get(limiter.resolve(bucket, limiter.now()))
          let reset = match model.view(old_key) {
            Some(v) if draw(2) == 0 => v.window
            _ => (before / 1000L + (draw(4) + 1).to_int64()) * 1000L
          }
          let left = draw(8)
          let retry = status == 429 && draw(4) != 0
          let delay = (draw(3) + 1) * 1000
          let named = match draw(4) {
            0 => None
            1 => Some(bucket)
            _ => Some(buckets[draw(buckets.length())])
          }
          let headers = if parsed {
            alias_quota("\{left}", "\{reset / 1000L}")
          } else {
            @http.Headers::empty()
          }
          let headers = if retry {
            headers.set("retry-after-ms", "\{delay}")
          } else {
            headers
          }
          let headers = if named is Some(key) {
            headers.set("key", key)
          } else {
            headers
          }
          limiter.release(bucket, status~, headers~)
          pending[bucket] -= 1
          let event = if parsed || retry {
            Some({
              window: if parsed {
                reset
              } else {
                before + delay.to_int64()
              },
              remaining: if retry {
                0
              } else {
                left
              },
              until: if retry {
                before + delay.to_int64()
              } else {
                reset
              },
              retry,
              block: if retry {
                before + delay.to_int64()
              } else {
                before
              },
            })
          } else {
            None
          }
          model.release(bucket, named, event, before)
          // Admission debt may make implementation quota smaller than the
          // reference ceiling. Independently pin monotonicity to its actual
          // pre-transition quota so even an increase below that ceiling fails.
          if old is Some(old) &&
            (old.until > before || old.blocked_until > before) {
            let current = limiter.states[limiter.resolve(bucket, limiter.now())]
            assert_true(current.blocked_until >= old.blocked_until)
            if current.window_reset == old.window_reset {
              assert_true(current.value.remaining <= old.value.remaining)
            }
          }
        } else {
          clock.advance(
            match draw(4) {
              0 => 1000
              1 => 3_599_000
              2 => 3_600_000
              _ => 0
            },
          )
          if operation == 9 {
            limiter.sweep_states(limiter.now(), force=true)
          }
        }
        let now = clock.now_unix_ms()
        model.expire(now)
        for bucket in buckets {
          let actual = limiter.state(bucket)
          if model.view(model.key(bucket)) is Some(expected) {
            if expected.until > now || expected.block > now {
              assert_true(
                actual is Some(_),
                msg="lost state: seed=\{seed}, step=\{step}, bucket=\{bucket}, now=\{now}, expected window=\{expected.window}, left=\{expected.remaining}, until=\{expected.until}, block=\{expected.block}",
              )
              let record = limiter.states[limiter.resolve(bucket, limiter.now())]
              assert_eq(record.window_reset, expected.window)
              assert_true(record.blocked_until >= expected.block)
              assert_true(record.value.remaining <= expected.remaining)
            }
          }
        }
      }
      for bucket in buckets {
        for _ in 0..<pending.get(bucket).unwrap_or(0) {
          limiter.release(bucket, status=0, headers=@http.Headers::empty())
        }
      }
      assert_eq(limiter.admissions.length(), 0)
    }
  })
}
