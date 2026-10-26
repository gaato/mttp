///|
pub(all) enum ServerPhase {
  Running
  Draining
  Stopped
}

///|
pub(all) struct Lifecycle {
  phase : ServerPhase
  connections : @persistent.HashMap[Int64, Bool]
  background : @persistent.HashMap[Int64, Unit]
}

///|
pub(all) enum ServerEvent {
  Accepted(Int64)
  Activity(Int64, Bool)
  Finished(Int64)
  BackgroundStarted(Int64)
  BackgroundFinished(Int64)
  Stop
  DrainExpired
  AcceptFailed
}

///|
pub(all) enum ServerAction {
  StopAccept
  CloseConnection(Int64)
  CancelConnection(Int64)
  CancelBackground(Int64)
  ReportAccept
}

///|
pub(all) struct ServerChange {
  state : Lifecycle
  actions : @vector.Vector[ServerAction]
}

///|
pub fn Lifecycle::new() -> Lifecycle {
  {
    phase: Running,
    connections: @persistent.HashMap::new(),
    background: @persistent.HashMap::new(),
  }
}

///|
pub fn Lifecycle::stopping(self : Lifecycle) -> Bool {
  !(self.phase is Running)
}

///|
pub fn Lifecycle::drained(self : Lifecycle) -> Bool {
  self.connections.length() == 0 && self.background.length() == 0
}

///|
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
