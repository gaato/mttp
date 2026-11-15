///|
/// Runs `scenario` under FIFO order and then under `seeds` seeded schedules
/// (seeds 0 to `seeds - 1`), and fails with a short reproduction when one of
/// them fails.
///
/// `scenario` builds its Driver with the `Schedule` it is given (through
/// `Driver::new(schedule~)` or `run_sync(f, schedule~)`) and raises when the
/// run goes wrong. It must depend only on that schedule. The orderings a
/// schedule can take are the ones a real runtime can produce (see
/// `Driver::new`), so a failure under any of them is a bug in the code under
/// test or an assertion that holds only in FIFO order.
///
/// A failing seed is replayed to confirm it is deterministic, and its list of
/// choices is shrunk with delta debugging (at most `max_runs` replays), then
/// each choice left that is not 0 is tried as 0 (one replay each). The
/// failure message names the seed, the original choices, the shrunk ones and
/// the shrunk run's error, and ends with the call that replays them, to paste
/// into a regression test. When the FIFO run meets no decision point, every
/// seed would run the same way, so the seeds are skipped.
///
/// ```mbt check
/// test {
///   let scenario = (schedule : @driver.Schedule) => {
///     let d = @driver.Driver::new(schedule~)
///     let coordination = @sim.SimCoordination::new(d)
///     let (a_peer, a) = @sim.pair(coordination)
///     let (b_peer, b) = @sim.pair(coordination)
///     let seen = []
///     d.run(() => {
///       let a_reader = d.spawn(() => seen.push(a.read(max_len=8)))
///       let b_reader = d.spawn(() => seen.push(b.read(max_len=8)))
///       d.pause()
///       // Either reader may see its peer's bytes first.
///       a_peer.write(b"a")
///       b_peer.write(b"b")
///       ignore(a_reader.wait())
///       ignore(b_reader.wait())
///     })
///     // Order-independent: holds under every schedule.
///     assert_eq(seen.length(), 2)
///   }
///   @sim.explore(scenario)
/// }
/// ```
pub fn explore(
  scenario : (@driver.Schedule) -> Unit raise,
  seeds~ : Int32 = 32,
  max_runs~ : Int32 = 256,
) -> Unit raise {
  let fifo = @driver.Schedule::replay([])
  if attempt(scenario, fifo) is Some(error) {
    fail("fails in FIFO order, before any seed:\n\{error}")
  }
  if fifo.choices().is_empty() {
    return
  }
  for seed in 0..<seeds {
    let schedule = @driver.Schedule::seeded(seed)
    guard attempt(scenario, schedule) is Some(error) else { continue }
    let choices = trim(schedule.choices())
    let replays = (list : Array[Int32]) => {
      attempt(scenario, @driver.Schedule::replay(list))
    }
    match replays(choices) {
      Some(again) if again == error => ()
      outcome => {
        let replayed = match outcome {
          Some(again) => "failed differently:\n\{again}"
          None => "passed"
        }
        fail(
          (
            $|seed \{seed} of \{seeds} fails, but replaying its choices \{list(choices)} \{replayed}
            $|so the scenario does not depend on its schedule alone. The seed's error:
            $|\{error}
          ),
        )
      }
    }
    let shrunk = ddmin(choices, max_runs~, list => replays(list) is Some(_))
    let minimal = zero_out(shrunk.steps, list => replays(list) is Some(_))
    // The run that kept `minimal` failed; one that passes now would be a
    // nondeterminism the first replay did not catch.
    let minimal_error = replays(minimal).unwrap_or("(passed when replayed)")
    let runs = if shrunk.runs == 1 { "1 run" } else { "\{shrunk.runs} runs" }
    let bound = if shrunk.exhausted { ", stopped at the run bound" } else { "" }
    fail(
      (
        $|seed \{seed} of \{seeds} fails:
        $|\{error}
        $|its choices: \{list(choices)}
        $|ddmin shrank them to \{list(minimal)} in \{runs}\{bound}, which fail with:
        $|\{minimal_error}
        $|replay: scenario(@driver.Schedule::replay(\{list(minimal)}))
      ),
    )
  }
}

///|
/// `choices` as a MoonBit array literal.
fn list(choices : Array[Int32]) -> String {
  "[" + choices.map(c => c.to_string()).join(", ") + "]"
}

///|
/// The text of the error `scenario` raises under `schedule`, if any.
fn attempt(
  scenario : (@driver.Schedule) -> Unit raise,
  schedule : @driver.Schedule,
) -> String? {
  try scenario(schedule) catch {
    Failure(message) => Some(message)
    error => Some("\{Repr(error)}")
  } noraise {
    _ => None
  }
}

///|
/// `choices` without its trailing zeros, which a replay takes anyway.
fn trim(choices : Array[Int32]) -> Array[Int32] {
  let mut end = choices.length()
  while end > 0 && choices[end - 1] == 0 {
    end -= 1
  }
  choices[:end].to_owned()
}

///|
/// Sets each nonzero choice of a failing list to 0 (FIFO) where the list
/// still fails, then trims it: ddmin only removes choices, and a removal
/// shifts the later ones onto other decision points.
fn zero_out(
  choices : Array[Int32],
  fails : (Array[Int32]) -> Bool,
) -> Array[Int32] {
  let current = choices.copy()
  for i in 0..<current.length() {
    if current[i] != 0 {
      let candidate = current.copy()
      candidate[i] = 0
      if fails(candidate) {
        current[i] = 0
      }
    }
  }
  trim(current)
}

///|
/// What `ddmin` found: a failing subsequence of its input, how many times it
/// ran the predicate, and whether the run bound stopped it early. Without
/// the bound, `steps` is 1-minimal: removing any one step makes it pass.
priv struct Shrunk[T] {
  steps : Array[T]
  runs : Int32
  exhausted : Bool
}

///|
/// Shrinks a failing input with Zeller's delta debugging (ddmin): splits the
/// current failing sequence into `n` chunks, keeps a chunk or a complement
/// that still fails, and otherwise doubles `n` until the chunks are single
/// steps. The empty sequence is tried first.
///
/// `fails(input)` is assumed, not re-run. Kept steps stay in input order, a
/// sequence is never run twice, and `fails` runs at most `max_runs` times;
/// at the bound the smallest failing sequence so far is returned.
fn[T] ddmin(
  input : Array[T],
  fails : (Array[T]) -> Bool,
  max_runs~ : Int32,
) -> Shrunk[T] {
  let search = Search::{ input, fails, max_runs, outcomes: Map([]), runs: 0, }
  let mut current = Array::makei(input.length(), i => i)
  let mut exhausted = false
  if current.length() > 0 {
    match search.probe([]) {
      Some(true) => current = []
      Some(false) => ()
      None => exhausted = true
    }
  }
  let mut n = 2
  while !exhausted && current.length() >= 2 {
    let parts = chunks(current.length(), n).map(range => {
      current[range.0:range.1].to_owned()
    })
    let mut reduced = false
    for part in parts {
      match search.probe(part) {
        Some(true) => {
          current = part
          n = 2
          reduced = true
          break
        }
        Some(false) => ()
        None => {
          exhausted = true
          break
        }
      }
    }
    // With two chunks each complement is the other chunk, already tried.
    if !reduced && !exhausted && n > 2 {
      for i in 0..<parts.length() {
        let rest = complement(parts, i)
        match search.probe(rest) {
          Some(true) => {
            current = rest
            n = (n - 1).max(2)
            reduced = true
            break
          }
          Some(false) => ()
          None => {
            exhausted = true
            break
          }
        }
      }
    }
    if !reduced && !exhausted {
      if n >= current.length() {
        break
      }
      n = (n * 2).min(current.length())
    }
  }
  { steps: current.map(i => input[i]), runs: search.runs, exhausted, }
}

///|
/// The predicate with its memo and run budget. Sequences are kept as input
/// indices, which also key the memo.
priv struct Search[T] {
  input : Array[T]
  fails : (Array[T]) -> Bool
  max_runs : Int32
  outcomes : Map[String, Bool]
  mut runs : Int32
}

///|
/// Whether the steps at `indices` fail, or `None` once the budget is spent.
fn[T] Search::probe(self : Search[T], indices : Array[Int32]) -> Bool? {
  let key = indices.map(i => i.to_string()).join(",")
  if self.outcomes.get(key) is Some(outcome) {
    return Some(outcome)
  }
  if self.runs >= self.max_runs {
    return None
  }
  self.runs += 1
  let outcome = (self.fails)(indices.map(i => self.input[i]))
  self.outcomes[key] = outcome
  Some(outcome)
}

///|
/// `[start, end)` of each of `n` contiguous chunks of `length` items, as even
/// as integer division makes them. `n` is at most `length`.
fn chunks(length : Int32, n : Int32) -> Array[(Int32, Int32)] {
  Array::makei(n, i => (i * length / n, (i + 1) * length / n))
}

///|
/// Every part but the one at `skip`, in order.
fn complement(parts : Array[Array[Int32]], skip : Int32) -> Array[Int32] {
  let rest : Array[Int32] = []
  for i, part in parts {
    if i != skip {
      rest.append(part)
    }
  }
  rest
}
