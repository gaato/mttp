// Seeded schedules. A Driver without a Schedule runs ready tasks strictly in
// FIFO order and fires due timers in (deadline, arming) order. With one, the
// driver asks the Schedule at every point where gaato/mttp's runtime
// (core/async) could order things differently, and nowhere else:
//
// S1. An I/O event (a wake made inside `io_event`) may reach its task later
//     than the driver delivered it: the task can be overtaken by tasks that
//     became ready after it. A ready task is only ever overtaken through a
//     run of such tasks at the front of the queue, so every other ready
//     task keeps its FIFO place. On core/async the poller reports readiness
//     between scheduling rounds, at a moment set by the transport and the
//     peer, so delivering the event later is a real outcome. The delay
//     never crosses a time advance: auto-advance waits until no task is
//     ready, and manual advances clear the pending I/O-delay marks.
//
// Everything the program orders itself keeps core/async's FIFO order: spawn,
// pause, signal, gate and join wakes, cancellation, and the order of timer
// firings relative to ready tasks. Timers always fire in (deadline, arming)
// order: a timer armed later for the same deadline cannot precede one armed
// earlier. Exploring those would report failures no runtime can produce.

///|
/// Which of the orderings a real runtime allows a Driver takes: FIFO (no
/// schedule), pseudo-random from a seed, or a recorded list of choices.
///
/// A choice is an index among the candidates at one decision point (S1 in
/// this file's notes); 0 is the FIFO candidate, an index past the last
/// candidate takes the last one, and a replay that runs out of choices
/// continues in FIFO order. `choices` returns the indices taken, so a failing
/// seed's schedule can be replayed and shrunk. A Schedule is stateful: give
/// each run a fresh one.
pub struct Schedule {
  priv mut state : UInt64
  priv seeded : Bool
  priv recorded : Array[Int32]
  priv mut cursor : Int32
  priv taken : Array[Int32]
}

///|
/// A schedule that picks among the candidates pseudo-randomly, the same way
/// for the same seed on every target.
pub fn Schedule::seeded(seed : Int32) -> Schedule {
  {
    state: seed.to_int64().reinterpret_as_uint64(),
    seeded: true,
    recorded: [],
    cursor: 0,
    taken: [],
  }
}

///|
/// A schedule that takes `choices` in order and then continues in FIFO
/// order, for replaying a list a failing seed printed.
///
/// ```mbt check
/// test {
///   let order = []
///   let run = (schedule : @driver.Schedule) => {
///     let d = @driver.Driver::new(schedule~)
///     d.run(() => {
///       let reader = (name : String) => {
///         let mut waker : @driver.Waker? = None
///         let task = d.spawn(() => {
///           d.park(w => waker = Some(w))
///           order.push(name)
///         })
///         (task, () => waker)
///       }
///       let (a, wa) = reader("a")
///       let (b, wb) = reader("b")
///       d.pause()
///       // Two peers' data arrive: a's first, but it may reach a later.
///       @driver.io_event(() => {
///         if wa() is Some(w) {
///           w.wake()
///         }
///         if wb() is Some(w) {
///           w.wake()
///         }
///       })
///       ignore(a.wait())
///       ignore(b.wait())
///     })
///     schedule.choices()
///   }
///   // FIFO, at two decision points: a or b first, then b or main (woken
///   // by a's end) first.
///   assert_eq(run(@driver.Schedule::replay([])), [0, 0])
///   assert_eq(order, ["a", "b"])
///   order.clear()
///   assert_eq(run(@driver.Schedule::replay([1])), [1])
///   assert_eq(order, ["b", "a"])
/// }
/// ```
pub fn Schedule::replay(choices : Array[Int32]) -> Schedule {
  { state: 0UL, seeded: false, recorded: choices.copy(), cursor: 0, taken: [], }
}

///|
/// The index taken at each decision point so far, in order.
pub fn Schedule::choices(self : Schedule) -> Array[Int32] {
  self.taken.copy()
}

///|
/// Picks one of `candidates` (at least 2) and records it.
fn Schedule::choose(self : Schedule, candidates : Int32) -> Int32 {
  let index = if self.seeded {
    // splitmix64: identical on every target, and good enough to spread
    // small seeds over the candidates.
    self.state += 0x9E3779B97F4A7C15UL
    let mut z = self.state
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
    z = z ^ (z >> 31)
    (z % candidates.to_uint64()).to_int()
  } else if self.cursor < self.recorded.length() {
    let wanted = self.recorded[self.cursor]
    self.cursor += 1
    wanted.max(0).min(candidates - 1)
  } else {
    0
  }
  self.taken.push(index)
  index
}

///|
/// How many `io_event` calls are running; a wake made inside one is an I/O
/// event (S1).
let io_depth : Ref[Int32] = { val: 0, }

///|
/// Runs `f` as the arrival of an I/O event: the tasks it wakes may, under a
/// seeded or replayed `Schedule`, run after tasks that become ready later
/// at the same virtual instant, as data or EOF from a peer may reach its
/// reader at any time after it was sent. Without a schedule it is `f()`.
/// The sim doubles of connections wrap
/// what they deliver to the other end in it; use it in a double of anything
/// whose completion the transport or the peer times.
pub fn io_event(f : () -> Unit) -> Unit {
  io_depth.val += 1
  defer {
    io_depth.val -= 1
  }
  f()
}

///|
/// The next task to resume: the oldest ready one, or under a schedule any
/// task that only I/O-event tasks are ahead of (S1).
fn Driver::next_ready(self : Driver) -> Task? {
  guard self.schedule is Some(schedule) && self.ready.length() >= 2 else {
    return self.ready.pop()
  }
  let mut lead = 0
  while lead < self.ready.length() && self.ready.get(lead).io_ready {
    lead += 1
  }
  let candidates = (lead + 1).min(self.ready.length())
  if candidates < 2 {
    return self.ready.pop()
  }
  match schedule.choose(candidates) {
    0 => self.ready.pop()
    index => Some(self.ready.remove_at(index))
  }
}

///|
/// Ends pending I/O delays before time moves: a wake at the new instant
/// cannot overtake an event already delivered at the old one, even when
/// manual time control advances with ready tasks still queued.
fn Driver::end_io_delays(self : Driver) -> Unit {
  for i in 0..<self.ready.length() {
    self.ready.get(i).io_ready = false
  }
}
