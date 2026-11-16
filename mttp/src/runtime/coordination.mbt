///|
priv struct RuntimeSignal {
  mut notified : Bool
  changed : @cond_var.Cond
}

///|
impl @rt.Signal for RuntimeSignal with fn wait(self) {
  while !self.notified {
    self.changed.wait()
  }
}

///|
impl @rt.Signal for RuntimeSignal with fn notify(self) {
  self.notified = true
  self.changed.broadcast()
}

///|
/// Structured connection coordination on moonbitlang/core/async.
pub struct RuntimeCoordination {}

///|
/// Uses structured runtime tasks and condition variables for connection work.
pub fn RuntimeCoordination::new() -> RuntimeCoordination {
  RuntimeCoordination::{ }
}

///|
/// Makes coordination operations available as methods.
pub extend RuntimeCoordination with @rt.Coordination::{
  signal,
  supervise,
  protect,
}

///|
/// Lets a bounded operation finish before a pending cancellation is delivered
/// at the next cancellable suspension, using the runtime's task-local shield.
pub impl @rt.Coordination for RuntimeCoordination with fn protect(_, work~) {
  @async.protect_from_cancel(() => work()) catch {
    @mttp_core.TransportError(..) as error => raise error
    error =>
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Unknown,
        detail=error.to_string(),
      )
  }
}

///|
/// Creates a sticky one-shot runtime notification.
pub impl @rt.Coordination for RuntimeCoordination with fn signal(_) {
  RuntimeSignal::{ notified: false, changed: @cond_var.Cond(), }
}

///|
/// Preserves the first delivered outcome and waits for both children's cleanup.
pub impl @rt.Coordination for RuntimeCoordination with fn supervise(
  _,
  primary~,
  monitor~,
) {
  let failure : Ref[@mttp_core.TransportError?] = Ref(None)
  let completed = Ref(false)
  @async.with_task_group(group => {
    // The group callback is already a structured child. Run primary there
    // instead of creating another child just to wait for its result.
    group.spawn_bg(no_wait=true, () => {
      monitor() catch {
        error =>
          if !completed.val {
            if failure.val is None {
              failure.val = Some(error)
            }
            group.return_immediately()
          }
      }
    })
    primary() catch {
      error => if failure.val is None { failure.val = Some(error) }
    }
    completed.val = true
  }) catch {
    @mttp_core.TransportError(..) as error => raise error
    error =>
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Unknown,
        detail=error.to_string(),
      )
  }
  // A synchronous primary may complete the group while cancelling its
  // caller. Preserve that caller's signal after both children have joined.
  if @async.is_being_cancelled() {
    @async.pause()
  }
  if failure.val is Some(error) {
    raise error
  }
}
