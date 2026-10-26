///|
priv struct RuntimeSignal {
  mut notified : Bool
  changed : @cond_var.Cond
}

///|
impl @conn.Signal for RuntimeSignal with fn wait(self) {
  while !self.notified {
    self.changed.wait()
  }
}

///|
impl @conn.Signal for RuntimeSignal with fn notify(self) {
  self.notified = true
  self.changed.broadcast()
}

///|
/// Structured connection coordination on moonbitlang/async.
pub struct RuntimeCoordination {}

///|
/// Uses structured runtime tasks and condition variables for connection work.
pub fn RuntimeCoordination::new() -> RuntimeCoordination {
  RuntimeCoordination::{ }
}

///|
/// Makes coordination operations available as methods.
pub extend RuntimeCoordination with @conn.Coordination::{signal, supervise}

///|
/// Creates a sticky one-shot runtime notification.
pub impl @conn.Coordination for RuntimeCoordination with fn signal(_) {
  RuntimeSignal::{ notified: false, changed: @cond_var.Cond(), }
}

///|
/// Preserves the first delivered outcome and waits for both children's cleanup.
pub impl @conn.Coordination for RuntimeCoordination with fn supervise(
  _,
  primary~,
  monitor~,
) {
  let failure : Ref[@model.TransportError?] = Ref(None)
  let completed = Ref(false)
  @async.with_task_group(group => {
    let work = group.spawn(
      () => {
        primary() catch {
          error => if failure.val is None { failure.val = Some(error) }
        }
        completed.val = true
      },
      allow_failure=true,
    )
    group.spawn_bg(no_wait=true, () => {
      monitor() catch {
        error =>
          if !completed.val {
            if failure.val is None {
              failure.val = Some(error)
            }
            work.cancel()
          }
      }
    })
    work.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
    if failure.val is Some(error) {
      raise error
    }
  }) catch {
    @model.TransportError(..) as error => raise error
    error =>
      raise @model.TransportError(
        kind=Network,
        phase=Unknown,
        detail=error.to_string(),
      )
  }
}
