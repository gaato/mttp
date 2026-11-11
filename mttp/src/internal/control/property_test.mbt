// Property tests: random event sequences against a reference model (slots)
// or against invariants (pool, lifecycle), each step also checking that the
// previous snapshot is unchanged.

///|
#derive(Debug)
priv enum SlotOp {
  Acquire(Int32)
  Release(Int32)
  Abandon(Int32)
  Stop
}

///|
fn gen_slot_ops() -> @qc.Generator[Array[SlotOp]] {
  @qc.frequency([
    (8, @qc.int_range(0, 3).map(n => SlotOp::Acquire(n))),
    (6, @qc.int_range(0, 3).map(n => SlotOp::Release(n))),
    (3, @qc.int_range(0, 8).map(n => SlotOp::Abandon(n))),
    (1, @qc.pure(SlotOp::Stop)),
  ]).array_with_size(120)
}

///|
/// The admission rules restated with plain arrays: counts per origin, the
/// queue in arrival order, and the closed flag.
priv struct SlotModel {
  max_total : Int32
  max_per_origin : Int32
  held : Array[Int32]
  queue : Array[(Int64, Int32)]
  mut closed : Bool
}

///|
fn SlotModel::fits(self : SlotModel, origin : Int32) -> Bool {
  self.held.fold(init=0, (a, b) => a + b) < self.max_total &&
  self.held[origin] < self.max_per_origin
}

///|
fn SlotModel::grant_waiters(self : SlotModel) -> Array[(Int64, String)] {
  let granted = []
  let kept = []
  for entry in self.queue {
    let (id, origin) = entry
    if !self.closed && self.fits(origin) {
      self.held[origin] += 1
      granted.push((id, "granted"))
    } else {
      kept.push(entry)
    }
  }
  self.queue.clear()
  self.queue.append(kept)
  granted
}

///|
fn notified(change : @control.SlotChange) -> Array[(Int64, String)] {
  change.notifications
  .iter()
  .map(n => {
    let (id, state) = n
    let label = match state {
      Waiting => "waiting"
      Granted => "granted"
      Refused => "refused"
    }
    (id, label)
  })
  .collect()
}

///|
let origins : Array[String] = ["a", "b", "c"]

///|
test "slot transitions match the reference model on random sequences" {
  let caps = [(1, 1), (2, 1), (3, 2), (4, 4)]
  for seed in 0UL..<40UL {
    let (max_total, max_per_origin) = caps[(seed % 4UL).to_int()]
    let model = SlotModel::{
      max_total,
      max_per_origin,
      held: [0, 0, 0],
      queue: [],
      closed: false,
    }
    let mut state = @control.SlotState::new(max_total~, max_per_origin~)
    let mut next_id = 0L
    for op in gen_slot_ops().sample(seed~) {
      let before = state
      let snapshot = (before.in_use, before.waiting.length(), before.closed)
      let (change, expected) = match op {
        Acquire(origin) => {
          next_id += 1L
          let expected = if model.closed {
            [(next_id, "refused")]
          } else if model.fits(origin) {
            model.held[origin] += 1
            [(next_id, "granted")]
          } else {
            model.queue.push((next_id, origin))
            []
          }
          (state.acquire(next_id, origins[origin]), expected)
        }
        Release(origin) => {
          let expected = if model.held[origin] > 0 {
            model.held[origin] -= 1
            model.grant_waiters()
          } else {
            []
          }
          (state.release(origins[origin]), expected)
        }
        Abandon(pick) => {
          let id = if model.queue.is_empty() {
            next_id + 100L
          } else {
            model.queue[pick % model.queue.length()].0
          }
          model.queue.retain(entry => entry.0 != id)
          (state.abandon(id), [(id, "refused")])
        }
        Stop => {
          let expected = if model.closed {
            []
          } else {
            model.queue.map(entry => (entry.0, "refused"))
          }
          model.closed = true
          model.queue.clear()
          (state.stop(), expected)
        }
      }
      state = change.state
      assert_eq(notified(change), expected, msg="\{Repr(op)} seed \{seed}")
      assert_eq(
        (before.in_use, before.waiting.length(), before.closed),
        snapshot,
      )
      assert_eq(state.in_use, model.held.fold(init=0, (a, b) => a + b))
      for i, origin in origins {
        assert_eq(state.per_origin.get(origin).unwrap_or(0), model.held[i])
      }
      assert_eq(
        state.waiting.iter().map(p => p.id).collect(),
        model.queue.map(entry => entry.0),
      )
      assert_eq(state.closed, model.closed)
      // No waiter is left behind a slot it fits.
      assert_true(state.waiting.iter().all(p => !state.fits(p.origin)))
    }
  }
}

///|
priv enum PoolOp {
  Put(Int32, Int32, Int32)
  Take(Int32, Int32, Int32)
  Drain
}

///|
fn gen_pool_ops() -> @qc.Generator[Array[PoolOp]] {
  let origin = @qc.int_range(0, 3)
  let agent = @qc.int_range(0, 3)
  // Mostly forward steps of the clock, sometimes backward.
  let step = @qc.int_range(-3, 12)
  @qc.frequency([
    (6, origin.zip_with3(agent, step, (o, a, dt) => PoolOp::Put(o, a, dt))),
    (6, origin.zip_with3(agent, step, (o, a, dt) => PoolOp::Take(o, a, dt))),
    (1, @qc.pure(PoolOp::Drain)),
  ]).array_with_size(150)
}

///|
fn agent_of(n : Int32) -> String? {
  if n == 0 {
    None
  } else {
    Some("agent-\{n}")
  }
}

///|
test "pool transitions keep caps and account for every connection once" {
  for seed in 0UL..<40UL {
    let max_total = 1 + (seed % 5UL).to_int()
    let max_per_origin = 1 + (seed % 3UL).to_int()
    let mut state = @control.PoolState::new(
      max_total~,
      max_per_origin~,
      idle_max_ms=20,
    )
    // Where each id ended up: parked (with its key and agent), taken back,
    // or closed. Every id lands in exactly one place at a time.
    let parked : Map[Int64, (String, String?, Int64)] = Map([])
    let gone : Map[Int64, String] = Map([])
    let mut now = 0L
    let mut next_id = 0L
    for op in gen_pool_ops().sample(seed~) {
      let before = state
      let before_count = before.count()
      let change = match op {
        Put(o, a, dt) => {
          now += dt.to_int64()
          next_id += 1L
          parked[next_id] = (origins[o], agent_of(a), now)
          state.put(
            origins[o],
            { id: next_id, user_agent: agent_of(a), parked_at_ms: now, },
            now~,
          )
        }
        Take(o, a, dt) => {
          now += dt.to_int64()
          let (change, id) = state.take(origins[o], agent_of(a), now~)
          if id is Some(id) {
            guard parked.get(id) is Some((key, agent, at)) else {
              fail("took an id that is not parked")
            }
            assert_eq(key, origins[o])
            assert_eq(agent, agent_of(a))
            // A taken connection is younger than idle_max_ms, unless the
            // clock went back past its parking time.
            assert_true(now < at || now - at < 20L)
            parked.remove(id)
            gone[id] = "taken"
          }
          change
        }
        Drain => state.drain()
      }
      for id in change.close {
        assert_true(parked.contains(id), msg="closed an id twice or unknown")
        parked.remove(id)
        gone[id] = "closed"
      }
      state = change.state
      assert_eq(before.count(), before_count)
      assert_eq(state.count(), parked.length())
      assert_true(state.count() <= max_total)
      assert_true(state.parked.length() <= max_total)
      for _, entries in state.parked {
        assert_true(entries.length() > 0 && entries.length() <= max_per_origin)
      }
      if state.closed {
        assert_eq(state.count(), 0)
      }
    }
    assert_eq(parked.length() + gone.length(), next_id.to_int())
  }
}

///|
fn gen_server_events() -> @qc.Generator[Array[@control.ServerEvent]] {
  let id = @qc.int_range(1, 6).map(n => n.to_int64())
  @qc.frequency([
    (4, id.map(n => @control.ServerEvent::Accepted(n))),
    (
      5,
      id.zip_with(@qc.int_range(0, 2), (id, busy) => {
        @control.ServerEvent::Activity(id, busy == 1)
      }),
    ),
    (3, id.map(n => @control.ServerEvent::Finished(n))),
    (2, id.map(n => @control.ServerEvent::BackgroundStarted(n + 10L))),
    (2, id.map(n => @control.ServerEvent::BackgroundFinished(n + 10L))),
    (1, @qc.pure(@control.ServerEvent::Stop)),
    (1, @qc.pure(@control.ServerEvent::DrainExpired)),
    (1, @qc.pure(@control.ServerEvent::AcceptFailed)),
  ]).array_with_size(80)
}

///|
fn rank(phase : @control.ServerPhase) -> Int32 {
  match phase {
    Running => 0
    Draining => 1
    Stopped => 2
  }
}

///|
test "lifecycle transitions only move forward and leave no idle connection while stopping" {
  for seed in 0UL..<60UL {
    let mut state = @control.Lifecycle::new()
    // Connections the actions told the adapter to close.
    let closed : Map[Int64, Unit] = Map([])
    for event in gen_server_events().sample(seed~) {
      let before = state
      let before_rank = rank(before.phase)
      let change = state.step(event)
      for action in change.actions {
        if action is CloseConnection(id) {
          closed[id] = ()
        }
      }
      state = change.state
      assert_eq(rank(before.phase), before_rank)
      assert_true(rank(state.phase) >= before_rank)
      assert_eq(
        state.drained(),
        state.connections.length() == 0 && state.background.length() == 0,
      )
      if state.stopping() {
        for id, busy in state.connections {
          assert_true(busy || closed.contains(id), msg="idle \{id} kept open")
        }
        assert_true(change.actions.iter().all(a => !(a is ReportAccept)))
      }
      if state.phase is Stopped {
        for id, _ in state.connections {
          assert_true(closed.contains(id))
        }
      }
    }
  }
}
