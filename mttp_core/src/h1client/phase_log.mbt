///|
/// The `PhaseEvent`s of one send, reported to the request's
/// `@mttp_core.on_phase` callback in order and at most once each
/// (CONTRACT.md, Backend rule 13): an event that does not come after the
/// last one reported is dropped. So when a stale reused connection is
/// replaced, the replacement's `Dialed`, `TlsDone` and `Pooled` are not
/// reported again, and when the response begins before the upload ends,
/// `Written` is not reported after `FirstByte`.
priv struct PhaseLog {
  report : ((@mttp_core.PhaseEvent) -> Unit)?
  mut last : Int32
}

///|
/// The log of a send of `request`, silent when it has no callback.
fn PhaseLog::of(request : @mttp_core.Request) -> PhaseLog {
  { report: request.attributes.get(@mttp_core.on_phase), last: 0, }
}

///|
/// A log that reports nothing, for a connection between exchanges.
fn PhaseLog::none() -> PhaseLog {
  { report: None, last: 0, }
}

///|
/// The position of `event` in an exchange; 0 for an event this engine does
/// not know, which is never reported.
fn phase_rank(event : @mttp_core.PhaseEvent) -> Int32 {
  match event {
    Dialed(..) => 1
    TlsDone => 2
    Pooled(..) => 3
    Written => 4
    FirstByte => 5
    @mttp_core.PhaseEvent::.. => 0
  }
}

///|
fn PhaseLog::emit(self : PhaseLog, event : @mttp_core.PhaseEvent) -> Unit {
  guard self.report is Some(report) else { return }
  let rank = phase_rank(event)
  if rank > self.last {
    self.last = rank
    report(event)
  }
}
