// A deterministic, single-threaded scheduler for MoonBit async code with
// virtual time. No async runtime is involved: tasks are coroutines started
// with `%async.run`, parked with `%async.suspend`, and resumed only from
// `Driver::step`, so the native stack never grows with the number of steps.
// Misuse raises `DriverError`; nothing in this package aborts.

///|
/// What went wrong in a `Driver`. New kinds may be added, so a `match` on it
/// needs a wildcard arm.
#non_exhaustive
pub(all) enum DriverErrorKind {
  /// Every live task is parked and no timer is armed (auto-advance on), so
  /// nothing can ever wake one. `parked` counts the live tasks.
  Deadlock(parked~ : Int32)
  /// Every live task is parked (auto-advance off, as in `run_sync`): the
  /// computation waits for time to pass or for an event no task will send.
  Suspended(parked~ : Int32)
  /// The step budget (`max_steps`) of one `run` ran out: a livelock or an
  /// unbounded loop. `steps` counts the steps of that `run`.
  NoQuiescence(steps~ : Int32)
  /// `run` finished, but tasks were still alive after the driver cancelled
  /// them for `max_unwind_rounds` rounds: they kept spawning new tasks while
  /// unwinding. `live` counts them.
  UnwindIncomplete(live~ : Int32)
  /// A task spawned without `allow_failure` failed and no task was waiting
  /// on it. `cause` is its error.
  TaskFailed(label~ : String, cause~ : Error)
  /// The main task of `run` finished by cancellation.
  MainCancelled
  /// `run` or `step` was called from a task of the same driver.
  Reentrant
  /// A driver operation that needs a running task of that driver was called
  /// elsewhere: outside any task, or from a task of another driver.
  NotInTask
} derive(Debug)

///|
/// Formats a kind for debugging.
pub extend DriverErrorKind with @debug.Debug::{to_repr}

///|
/// The error a `Driver` raises. `detail` is a human-readable explanation;
/// match on `kind`, not on `detail`.
pub(all) suberror DriverError {
  DriverError(kind~ : DriverErrorKind, detail~ : String)
} derive(Debug)

///|
/// Formats a driver error for debugging.
pub extend DriverError with @debug.Debug::{to_repr}

///|
/// How many times `run` cancels the tasks still alive when it ends, before
/// it gives up with `UnwindIncomplete`. A task can only outlive a round by
/// spawning a new task while it unwinds.
pub let max_unwind_rounds : Int32 = 8

///|
/// What a parked task is resumed with.
pub(all) enum Resume {
  /// A waker made the task ready.
  Woken
  /// The task was cancelled while parked (or before it parked).
  Cancelled
} derive(Eq, Debug)

///|
/// Compares resume values.
pub extend Resume with Eq::{equal, not_equal}

///|
/// Formats a resume value for debugging.
pub extend Resume with @debug.Debug::{to_repr}

///|
priv enum State {
  Ready
  Running
  Parked
  Done
  Failed(Error)
  Cancelled
}

///|
/// A task spawned on a `Driver`.
pub struct Task {
  priv id : Int32
  priv label : String
  priv driver : Driver
  priv mut state : State
  priv mut cont : ((Resume) -> Unit)?
  priv mut cancel_requested : Bool
  priv mut cancel_mask : Int32
  priv mut gen : Int32
  priv joiners : Array[Waker]
  priv allow_failure : Bool
}

///|
/// A one-shot handle that makes a parked task ready again. A waker is bound
/// to one park: once the task has resumed, waking through it does nothing.
pub struct Waker {
  priv task : Task
  priv gen : Int32
}

///|
/// A timer armed with `Driver::add_timer`.
pub struct TimerHandle {
  priv at : Int64
  priv seq : Int32
  priv action : () -> Unit
  priv mut cancelled : Bool
}

///|
priv struct Fifo[T] {
  mut items : Array[T]
  mut head : Int32
}

///|
priv struct TimerHeap {
  data : Array[TimerHandle]
}

///|
/// A deterministic scheduler with virtual time. Tasks run one at a time, in
/// the order they became ready; time moves only when the driver advances it.
pub struct Driver {
  priv ready : Fifo[Task]
  priv timers : TimerHeap
  priv live : Map[Int32, Task]
  priv mut now : Int64
  priv mut current : Task?
  priv auto_advance : Bool
  priv max_steps : Int32
  priv mut budget_limit : Int32
  priv mut timer_firings : Int32
  priv mut in_step : Bool
  priv mut steps : Int32
  priv mut budget_base : Int32
  priv mut next_id : Int32
  priv mut next_seq : Int32
  priv mut failure : DriverError?
  priv mut running : Bool
}

///|
/// The driver whose `step` is running a task right now.
let active : Ref[Driver?] = { val: None, }

// ---------------------------------------------------------------- Fifo

///|
fn[T] Fifo::new() -> Fifo[T] {
  { items: [], head: 0, }
}

///|
fn[T] Fifo::push(self : Fifo[T], x : T) -> Unit {
  self.items.push(x)
}

///|
fn[T] Fifo::length(self : Fifo[T]) -> Int32 {
  self.items.length() - self.head
}

///|
fn[T] Fifo::pop(self : Fifo[T]) -> T? {
  if self.head >= self.items.length() {
    return None
  }
  let x = self.items[self.head]
  self.head += 1
  if self.head == self.items.length() {
    self.items.clear()
    self.head = 0
  } else if self.head >= 4096 && self.head * 2 >= self.items.length() {
    let rest = []
    for i in self.head..<self.items.length() {
      rest.push(self.items[i])
    }
    self.items = rest
    self.head = 0
  }
  Some(x)
}

// ----------------------------------------------------------- TimerHeap

///|
fn earlier(a : TimerHandle, b : TimerHandle) -> Bool {
  a.at < b.at || (a.at == b.at && a.seq < b.seq)
}

///|
fn TimerHeap::push(self : TimerHeap, t : TimerHandle) -> Unit {
  let data = self.data
  data.push(t)
  let mut i = data.length() - 1
  while i > 0 {
    let parent = (i - 1) / 2
    if earlier(data[i], data[parent]) {
      let tmp = data[i]
      data[i] = data[parent]
      data[parent] = tmp
      i = parent
    } else {
      break
    }
  }
}

///|
fn TimerHeap::remove_top(self : TimerHeap) -> Unit {
  let data = self.data
  guard data.pop() is Some(last) else { return }
  if data.is_empty() {
    return
  }
  data[0] = last
  let n = data.length()
  let mut i = 0
  while true {
    let l = 2 * i + 1
    let r = l + 1
    let mut m = i
    if l < n && earlier(data[l], data[m]) {
      m = l
    }
    if r < n && earlier(data[r], data[m]) {
      m = r
    }
    if m == i {
      break
    }
    let tmp = data[i]
    data[i] = data[m]
    data[m] = tmp
    i = m
  }
}

///|
/// The earliest timer that is still armed; cancelled ones are dropped here.
fn TimerHeap::peek(self : TimerHeap) -> TimerHandle? {
  while !self.data.is_empty() {
    let top = self.data[0]
    if !top.cancelled {
      return Some(top)
    }
    self.remove_top()
  }
  None
}

///|
fn TimerHeap::clear(self : TimerHeap) -> Unit {
  self.data.clear()
}

// --------------------------------------------------------------- Driver

///|
/// A driver at virtual time `start_ms`. With `auto_advance`, when no task is
/// ready, `run` jumps virtual time to the next armed timer; without it, `run`
/// raises `Suspended` instead. `max_steps` bounds task steps of one `run`
/// (and manual steps since its start) and independently bounds timer callbacks.
/// Past either budget, `step` raises `NoQuiescence` instead of hanging.
/// Cancellation cleanup has a
/// fresh budget per round, at least twice the number of live tasks, so an
/// exhausted execution budget does not prevent cancellation delivery.
/// A value below 1 makes the first task step raise.
pub fn Driver::new(
  auto_advance~ : Bool = true,
  max_steps~ : Int32 = 100_000_000,
  start_ms~ : Int64 = 0L,
) -> Driver {
  {
    ready: Fifo::new(),
    timers: { data: [], },
    live: {},
    now: start_ms,
    current: None,
    auto_advance,
    max_steps,
    budget_limit: max_steps,
    timer_firings: 0,
    in_step: false,
    steps: 0,
    budget_base: 0,
    next_id: 0,
    next_seq: 0,
    failure: None,
    running: false,
  }
}

///|
/// The current virtual time in milliseconds.
pub fn Driver::now(self : Driver) -> Int64 {
  self.now
}

///|
/// Steps run since the driver was created, over every `run`.
pub fn Driver::steps(self : Driver) -> Int32 {
  self.steps
}

///|
/// Tasks that have been spawned and have not finished.
pub fn Driver::live_tasks(self : Driver) -> Int32 {
  self.live.length()
}

///|
/// Tasks waiting in the ready queue.
pub fn Driver::ready_tasks(self : Driver) -> Int32 {
  self.ready.length()
}

///|
/// Armed timers, cancelled ones excluded.
pub fn Driver::pending_timers(self : Driver) -> Int32 {
  let mut n = 0
  for t in self.timers.data {
    if !t.cancelled {
      n += 1
    }
  }
  n
}

///|
/// Whether a task of this driver is running and calling into it right now.
fn Driver::is_stepping(self : Driver) -> Bool {
  active.val is Some(d) && physical_equal(d, self) && self.current is Some(_)
}

///|
/// The task this driver is running right now. Raises `NotInTask` when no
/// task of this driver is running.
pub fn Driver::current_task(self : Driver) -> Task raise DriverError {
  match self.current {
    Some(t) if self.is_stepping() => t
    _ =>
      raise DriverError(
        kind=NotInTask,
        detail="Driver::current_task called outside a task of this driver",
      )
  }
}

///|
/// Moves virtual time forward by `ms` (for manual control under `run_sync`
/// or between `step` calls); a negative `ms` does nothing. Timers that
/// become due fire on the next step.
pub fn Driver::advance(self : Driver, ms : Int32) -> Unit {
  if ms > 0 {
    self.now += ms.to_int64()
  }
}

///|
/// Starts `f` as a new task at the back of the ready queue. It runs on a
/// later step; a task cancelled before it starts still runs until its first
/// park, so a `defer` at the top of its body always runs.
/// A failure of a task with `allow_failure=false` that nobody is waiting on
/// fails the enclosing `run` with `TaskFailed`.
pub fn Driver::spawn(
  self : Driver,
  f : async () -> Unit,
  label~ : String = "",
  allow_failure~ : Bool = false,
) -> Task {
  self.next_id += 1
  let task : Task = {
    id: self.next_id,
    label,
    driver: self,
    state: Ready,
    cont: None,
    cancel_requested: false,
    cancel_mask: 0,
    gen: 0,
    joiners: [],
    allow_failure,
  }
  task.cont = Some(_ => self.start(task, f))
  self.live.set(task.id, task)
  self.ready.push(task)
  task
}

///|
fn Driver::start(self : Driver, task : Task, f : async () -> Unit) -> Unit {
  run_coroutine(() => {
    let outcome : State = capture_cancellation(
      () => {
        f()
        State::Done
      },
      handler=() => State::Cancelled,
    ) catch {
      e => State::Failed(e)
    }
    self.finish(task, outcome)
  })
}

///|
/// Records an error that `step` raises once the current step ends; the
/// first one wins.
fn Driver::report(self : Driver, e : DriverError) -> Unit {
  if self.failure is None {
    self.failure = Some(e)
  }
}

///|
fn Driver::finish(self : Driver, task : Task, outcome : State) -> Unit {
  task.state = outcome
  task.cont = None
  self.live.remove(task.id)
  match outcome {
    Failed(e) =>
      if !task.allow_failure && task.joiners.is_empty() {
        self.report(
          DriverError(
            kind=TaskFailed(label=task.label, cause=e),
            detail="task \{task.id} failed and no task waited on it",
          ),
        )
      }
    _ => ()
  }
  let joiners = task.joiners.copy()
  task.joiners.clear()
  for w in joiners {
    w.wake()
  }
}

///|
/// Arms a timer that runs `action` (synchronously, from `step`) once
/// virtual time reaches `at`. Timers with equal deadlines fire in the order
/// they were armed.
pub fn Driver::add_timer(
  self : Driver,
  at : Int64,
  action : () -> Unit,
) -> TimerHandle {
  self.next_seq += 1
  let h : TimerHandle = { at, seq: self.next_seq, action, cancelled: false, }
  self.timers.push(h)
  h
}

///|
/// Disarms the timer; it never fires afterwards. Cancelling a timer that
/// already fired does nothing.
pub fn TimerHandle::cancel(self : TimerHandle) -> Unit {
  self.cancelled = true
}

///|
fn Driver::fire_due(self : Driver) -> Unit raise DriverError {
  while self.timers.peek() is Some(t) && t.at <= self.now {
    if self.timer_firings >= self.budget_limit {
      raise DriverError(
        kind=NoQuiescence(steps=self.timer_firings),
        detail="timer callback budget exhausted",
      )
    }
    self.timer_firings += 1
    self.timers.remove_top()
    t.cancelled = true
    (t.action)()
  }
}

///|
/// Moves virtual time to the earliest armed timer. Returns false if none.
pub fn Driver::advance_to_next_timer(self : Driver) -> Bool {
  match self.timers.peek() {
    Some(t) => {
      if t.at > self.now {
        self.now = t.at
      }
      true
    }
    None => false
  }
}

///|
/// Fires due timers, then runs the oldest ready task until it parks or
/// finishes. Returns false when no task was ready.
///
/// Raises `Reentrant` when called from a task of this driver,
/// `NoQuiescence` once the step budget is spent, and the first error
/// reported during the step: `TaskFailed` for an unobserved task failure,
/// `NotInTask` for a park on a driver from a task that is not its own.
pub fn Driver::step(self : Driver) -> Bool raise DriverError {
  if self.in_step {
    raise DriverError(
      kind=Reentrant,
      detail="Driver::step called from a task of the same driver",
    )
  }
  self.in_step = true
  defer {
    self.in_step = false
  }
  self.fire_due()
  guard self.ready.pop() is Some(task) else { return false }
  guard task.cont is Some(k) else { return true }
  task.cont = None
  task.state = Running
  let saved_current = self.current
  let saved_active = active.val
  self.current = Some(task)
  active.val = Some(self)
  let r = if task.cancel_requested && task.cancel_mask == 0 {
    Resume::Cancelled
  } else {
    Resume::Woken
  }
  self.steps += 1
  k(r)
  self.current = saved_current
  active.val = saved_active
  if task.state is Running {
    // Suspended through something other than this driver: nothing here can
    // resume it, so it counts as parked for deadlock detection.
    task.state = Parked
  }
  if self.failure is Some(e) {
    self.failure = None
    raise e
  }
  let used = self.steps - self.budget_base
  if used > self.budget_limit {
    raise DriverError(
      kind=NoQuiescence(steps=used),
      detail="the step budget of \{self.max_steps} ran out",
    )
  }
  true
}

///|
/// Cancels every live task and runs them until they have unwound, for at
/// most `max_unwind_rounds` rounds. Time is not advanced: a task that parks
/// again while being cancelled resumes at once with Cancelled. Returns the
/// number of tasks still alive and the first error a step raised while
/// unwinding (other than the spent step budget, which ends the round).
fn Driver::shutdown(self : Driver) -> (Int32, DriverError?) {
  let mut rounds = 0
  let mut first_error : DriverError? = None
  // Cancelled tasks are woken directly. Discard due timer callbacks before
  // cleanup so a self-rearming timer cannot starve cancellation delivery.
  self.timers.clear()
  while !self.live.is_empty() && rounds < max_unwind_rounds {
    rounds += 1
    self.budget_base = self.steps
    self.timer_firings = 0
    self.budget_limit = self.max_steps.max(
      (self.live.length().to_int64() * 2L).min(2147483647L).to_int(),
    )
    let tasks = []
    for _, t in self.live {
      tasks.push(t)
    }
    for t in tasks {
      t.cancel()
    }
    while true {
      let progressed = self.step() catch {
        DriverError(kind=NoQuiescence(_), ..) => false
        e => {
          if first_error is None {
            first_error = Some(e)
          }
          true
        }
      }
      if !progressed {
        break
      }
    }
  }
  self.timers.clear()
  self.failure = None
  (self.live.length(), first_error)
}

///|
/// Steps until `main_task` finishes, advancing time when allowed.
fn Driver::drive(self : Driver, main_task : Task) -> Unit raise DriverError {
  while !main_task.is_finished() {
    if self.step() {
      continue
    }
    if self.auto_advance && self.advance_to_next_timer() {
      continue
    }
    let parked = self.live.length()
    if self.auto_advance {
      raise DriverError(
        kind=Deadlock(parked~),
        detail="every live task is parked and no timer is armed",
      )
    } else {
      raise DriverError(
        kind=Suspended(parked~),
        detail="every live task is parked and time does not advance",
      )
    }
  }
}

///|
/// Runs `main` and every task it spawns until `main` finishes, then cancels
/// the tasks still alive and lets them unwind. Returns `main`'s value or
/// raises its error.
///
/// Raises `DriverError`: `Deadlock` (or `Suspended` with auto-advance off)
/// when every task is parked and no timer can wake one, `NoQuiescence` when
/// the step budget runs out, `TaskFailed` when a task nobody waits on fails,
/// `MainCancelled` when `main` is cancelled, `UnwindIncomplete` when tasks
/// survive `max_unwind_rounds` rounds of cancellation, and `Reentrant` when
/// called from a task of this driver. Live tasks are cancelled and unwound
/// before it raises. When `main` succeeded, an error raised while the other
/// tasks unwind (such as `TaskFailed` for a task a `defer` spawned) is
/// raised in place of its value.
pub fn[X] Driver::run(self : Driver, main : async () -> X) -> X raise {
  if self.running || self.in_step {
    raise DriverError(
      kind=Reentrant,
      detail="Driver::run called while a run of the same driver is active",
    )
  }
  self.running = true
  defer {
    self.running = false
  }
  self.budget_base = self.steps
  self.budget_limit = self.max_steps
  self.timer_firings = 0
  self.failure = None
  let mut result : X? = None
  let main_task = self.spawn(
    () => result = Some(main()),
    label="main",
    allow_failure=true,
  )
  let error = try self.drive(main_task) catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  let (alive, unwind_error) = self.shutdown()
  if alive > 0 {
    raise DriverError(
      kind=UnwindIncomplete(live=alive),
      detail="tasks survived bounded cancellation cleanup",
    )
  }
  if error is Some(e) {
    raise e
  }
  match result {
    Some(x) => {
      if unwind_error is Some(e) {
        raise e
      }
      x
    }
    None =>
      match main_task.state {
        Failed(e) => raise e
        _ =>
          raise DriverError(
            kind=MainCancelled,
            detail="the main task was cancelled",
          )
      }
  }
}

///|
/// Parks the current task until a waker given to `register` is woken or the
/// task is cancelled. Returns Cancelled at once (without calling `register`)
/// if the task is already being cancelled. Never raises: the caller decides
/// how to unwind, which is what a FIFO gate needs.
///
/// Called anywhere but from a task of this driver, it parks nothing and
/// returns Cancelled; the driver that is stepping, if any, fails its `run`
/// with `NotInTask`.
pub async fn Driver::park_check_cancel(
  self : Driver,
  register : (Waker) -> Unit,
) -> Resume noraise + nocancel {
  guard self.is_stepping() && self.current is Some(task) else {
    if active.val is Some(stepping) {
      stepping.report(
        DriverError(
          kind=NotInTask,
          detail="a task parked on a driver that is not running it",
        ),
      )
    }
    return Resume::Cancelled
  }
  if task.cancel_requested && task.cancel_mask == 0 {
    return Resume::Cancelled
  }
  task.gen += 1
  let waker : Waker = { task, gen: task.gen, }
  suspend_coroutine(k => {
    task.state = Parked
    task.cont = Some(k)
    register(waker)
  })
}

///|
/// Like `park_check_cancel`, but a cancellation unwinds the caller.
pub async fn Driver::park(
  self : Driver,
  register : (Waker) -> Unit,
) -> Unit noraise {
  match self.park_check_cancel(register) {
    Woken => ()
    Cancelled => raise_cancellation()
  }
}

///|
/// Moves the current task to the back of the ready queue.
pub async fn Driver::pause(self : Driver) -> Unit noraise {
  self.park(w => w.wake())
}

///|
/// Parks the current task for `ms` of virtual time; a negative `ms` counts
/// as 0, which still yields to the other ready tasks once the timer fires.
pub async fn Driver::sleep(self : Driver, ms : Int32) -> Unit noraise {
  let at = self.now + (if ms > 0 { ms.to_int64() } else { 0L })
  let mut handle : TimerHandle? = None
  let r = self.park_check_cancel(w => {
    handle = Some(self.add_timer(at, () => w.wake()))
  })
  match r {
    Woken => ()
    Cancelled => {
      if handle is Some(h) {
        h.cancel()
      }
      raise_cancellation()
    }
  }
}

// ---------------------------------------------------------------- Waker

///|
/// Makes the parked task ready again. Does nothing if the task has resumed
/// since this waker was made, or has finished.
pub fn Waker::wake(self : Waker) -> Unit {
  let t = self.task
  if t.gen == self.gen && t.state is Parked && t.cont is Some(_) {
    t.state = Ready
    t.driver.ready.push(t)
  }
}

///|
/// The task this waker resumes.
pub fn Waker::task(self : Waker) -> Task {
  self.task
}

// ----------------------------------------------------------------- Task

///|
/// Requests cancellation. A parked task is made ready and resumes with
/// Cancelled; a ready or running task observes it at its next park. A task
/// that was woken and is cancelled before it resumes also resumes with
/// Cancelled, as in moonbitlang/core's scheduler.
pub fn Task::cancel(self : Task) -> Unit {
  match self.state {
    Done | Failed(_) | Cancelled => ()
    Parked => {
      self.cancel_requested = true
      if self.cont is Some(_) && self.cancel_mask == 0 {
        self.state = Ready
        self.driver.ready.push(self)
      }
    }
    Ready | Running => self.cancel_requested = true
  }
}

///|
/// Finishes structured cleanup before delivering pending cancellation at a
/// later suspension. The mask is task-local and supports nested cleanup.
pub async fn Driver::cancel_and_join(
  self : Driver,
  tasks : Array[Task],
) -> Unit noraise + nocancel {
  for task in tasks {
    task.cancel()
  }
  guard self.current is Some(current) else { return }
  current.cancel_mask += 1
  defer {
    current.cancel_mask -= 1
  }
  for task in tasks {
    while !task.is_finished() {
      ignore(self.park_check_cancel(waker => task.joiners.push(waker)))
    }
  }
}

///|
/// Whether the task has completed, failed or been cancelled.
pub fn Task::is_finished(self : Task) -> Bool {
  match self.state {
    Done | Failed(_) | Cancelled => true
    Ready | Running | Parked => false
  }
}

///|
/// Whether the task completed normally.
pub fn Task::is_done(self : Task) -> Bool {
  self.state is Done
}

///|
/// Whether the task finished by cancellation.
pub fn Task::is_cancelled(self : Task) -> Bool {
  self.state is Cancelled
}

///|
/// Whether the task is parked, waiting for a waker or a cancellation.
pub fn Task::is_parked(self : Task) -> Bool {
  self.state is Parked
}

///|
/// Whether `cancel` has been called on the task.
pub fn Task::is_cancel_requested(self : Task) -> Bool {
  self.cancel_requested
}

///|
/// The label given to `spawn`.
pub fn Task::label(self : Task) -> String {
  self.label
}

///|
/// Waits for the task to finish: true if it completed, false if it was
/// cancelled; raises its error if it failed. A task waited on does not fail
/// the enclosing `run` with `TaskFailed`.
pub async fn Task::wait(self : Task) -> Bool {
  while true {
    match self.state {
      Done => return true
      Cancelled => return false
      Failed(e) => raise e
      Ready | Running | Parked => self.driver.park(w => self.joiners.push(w))
    }
  }
  false
}

// ------------------------------------------------- ambient conveniences

///|
/// The driver running the current task. Raises `NotInTask` when no driver
/// is stepping a task.
pub fn current() -> Driver raise DriverError {
  match active.val {
    Some(d) => d
    None =>
      raise DriverError(kind=NotInTask, detail="no Driver is stepping a task")
  }
}

///|
/// `current().sleep(ms)`.
pub async fn sleep(ms : Int32) -> Unit raise DriverError {
  current().sleep(ms)
}

///|
/// `current().pause()`.
pub async fn pause() -> Unit raise DriverError {
  current().pause()
}

///|
/// `current().now()`.
pub fn now() -> Int64 raise DriverError {
  current().now()
}

///|
/// `current().spawn(f, label~, allow_failure~)`.
pub fn spawn(
  f : async () -> Unit,
  label~ : String = "",
  allow_failure~ : Bool = false,
) -> Task raise DriverError {
  current().spawn(f, label~, allow_failure~)
}

///|
/// `Driver::new(auto_advance=false).run(f)`: runs `f` and the tasks it
/// spawns to completion with time frozen. It refuses to wait rather than
/// hang: when every task is parked, it raises `Suspended`.
pub fn[X] run_sync(f : async () -> X) -> X raise {
  Driver::new(auto_advance=false).run(f)
}
