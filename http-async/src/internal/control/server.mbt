// The lifecycle of a listener and its connections: running, draining after
// a stop (idle connections close, busy ones finish their exchange), and
// stopped when the drain time runs out (everything is cancelled). The
// listener adapter keeps the connections and tasks; this state holds their
// ids and returns the actions to perform once it is committed.

///|
/// Where the listener is in its shutdown.
pub(all) enum ServerPhase {
  /// Accepting connections.
  Running
  /// Stopped accepting; busy connections finish their exchange.
  Draining
  /// The drain time ran out; everything left is cancelled.
  Stopped
}

///|
/// The listener's phase, its connections and its detached background work.
pub(all) struct Lifecycle {
  phase : ServerPhase
  /// The open connections, each with whether an exchange is running on it.
  connections : @persistent.HashMap[Int64, Bool]
  /// Background work started by handlers and not finished yet.
  background : @persistent.HashMap[Int64, Unit]
}

///|
/// An event the listener adapter observed.
pub(all) enum ServerEvent {
  /// A connection was accepted.
  Accepted(Int64)
  /// A connection became busy (`true`) or idle (`false`).
  Activity(Int64, Bool)
  /// A connection closed.
  Finished(Int64)
  /// A handler started background work.
  BackgroundStarted(Int64)
  /// Background work finished.
  BackgroundFinished(Int64)
  /// The owner asked the listener to stop.
  Stop
  /// The drain time ran out.
  DrainExpired
  /// Accepting a connection failed.
  AcceptFailed
}

///|
/// What the adapter does after committing a transition, in order.
pub(all) enum ServerAction {
  /// Stop accepting new connections.
  StopAccept
  /// Close a connection's socket.
  CloseConnection(Int64)
  /// Cancel a connection's task.
  CancelConnection(Int64)
  /// Cancel background work.
  CancelBackground(Int64)
  /// Report an accept failure to the owner.
  ReportAccept
}

///|
/// The state after an event, and the actions it requires.
pub(all) struct ServerChange {
  state : Lifecycle
  actions : @vector.Vector[ServerAction]
}

///|
/// A running listener with no connections.
pub fn Lifecycle::new() -> Lifecycle {
  {
    phase: Running,
    connections: @persistent.HashMap::new(),
    background: @persistent.HashMap::new(),
  }
}

///|
/// Whether a stop was requested.
pub fn Lifecycle::stopping(self : Lifecycle) -> Bool {
  !(self.phase is Running)
}

///|
/// Whether no connection and no background work is left.
pub fn Lifecycle::drained(self : Lifecycle) -> Bool {
  self.connections.length() == 0 && self.background.length() == 0
}

///|
/// Applies `event`. While stopping, accepted and newly idle connections
/// are closed and cancelled at once; after the drain time, background work
/// that starts is cancelled at once. Accept failures are reported only
/// while running, since stopping makes accepting fail by design.
pub fn Lifecycle::step(self : Lifecycle, event : ServerEvent) -> ServerChange {
  let none : @vector.Vector[ServerAction] = @vector.Vector::new()
  match event {
    Accepted(id) =>
      if self.stopping() {
        {
          state: self,
          actions: @vector.Vector([CloseConnection(id), CancelConnection(id)]),
        }
      } else {
        {
          state: { ..self, connections: self.connections.add(id, false), },
          actions: none,
        }
      }
    Activity(id, busy) => {
      guard self.connections.contains(id) else {
        return { state: self, actions: none, }
      }
      {
        state: { ..self, connections: self.connections.add(id, busy), },
        actions: if self.stopping() && !busy {
          @vector.Vector([CloseConnection(id), CancelConnection(id)])
        } else {
          none
        },
      }
    }
    Finished(id) =>
      {
        state: { ..self, connections: self.connections.remove(id), },
        actions: none,
      }
    BackgroundStarted(id) =>
      if self.phase is Stopped {
        { state: self, actions: @vector.Vector([CancelBackground(id)]), }
      } else {
        {
          state: { ..self, background: self.background.add(id, ()), },
          actions: none,
        }
      }
    BackgroundFinished(id) =>
      {
        state: { ..self, background: self.background.remove(id), },
        actions: none,
      }
    Stop => {
      if self.stopping() {
        return { state: self, actions: none, }
      }
      let actions = [StopAccept]
      for id, busy in self.connections {
        if !busy {
          actions.push(CloseConnection(id))
          actions.push(CancelConnection(id))
        }
      }
      {
        state: { ..self, phase: Draining, },
        actions: @vector.Vector(actions[:]),
      }
    }
    DrainExpired => {
      if self.phase is Stopped {
        return { state: self, actions: none, }
      }
      let actions = []
      for id, _ in self.connections {
        actions.push(CloseConnection(id))
        actions.push(CancelConnection(id))
      }
      for id, _ in self.background {
        actions.push(CancelBackground(id))
      }
      {
        state: { ..self, phase: Stopped, },
        actions: @vector.Vector(actions[:]),
      }
    }
    AcceptFailed =>
      {
        state: self,
        actions: if self.stopping() {
          none
        } else {
          @vector.Vector([ReportAccept])
        },
      }
  }
}
