///|
priv struct Connection {
  conn : &@rt.Conn
  mut task : @async.Task[Unit]?
}

///|
priv struct ServerState {
  mut control : @control.Lifecycle
  connections : Map[Int64, Connection]
  changed : @cond_var.Cond
  mut stop_accept : (() -> Unit)?
  background : Map[Int64, @async.Task[Unit]?]
  mut next_id : Int64
}

///|
fn ServerState::new() -> ServerState {
  {
    control: @control.Lifecycle::new(),
    connections: {},
    changed: @cond_var.Cond(),
    stop_accept: None,
    background: {},
    next_id: 0L,
  }
}

///|
// Commit pure decisions before interpreting resource effects, including wakeups.
fn ServerState::step(self : ServerState, event : @control.ServerEvent) -> Bool {
  let change = self.control.step(event)
  self.control = change.state
  let mut accept_failure = false
  for action in change.actions {
    match action {
      StopAccept => if self.stop_accept is Some(stop) { stop() }
      CloseConnection(id) =>
        if self.connections.get(id) is Some(c) {
          c.conn.close()
        }
      CancelConnection(id) =>
        if self.connections.get(id) is Some(c) {
          if c.task is Some(task) {
            task.cancel()
          }
        }
      CancelBackground(id) =>
        if self.background.get(id) is Some(Some(task)) {
          task.cancel()
        }
      ReportAccept => accept_failure = true
    }
  }
  self.changed.broadcast()
  accept_failure
}
