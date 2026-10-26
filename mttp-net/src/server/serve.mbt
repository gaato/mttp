///|
using @engine {type Wire, report}

///|
priv struct Connection {
  session : @engine.Connection
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
fn ServerState::step(self : ServerState, event : @control.ServerEvent) -> Bool {
  let change = self.control.step(event)
  self.control = change.state
  let mut accept_failure = false
  for action in change.actions {
    match action {
      StopAccept => if self.stop_accept is Some(stop) { stop() }
      CloseConnection(id) =>
        if self.connections.get(id) is Some(c) {
          c.session.wire.close()
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

///|
/// Serves bounded HTTP/1 connections; lifecycle decisions contain no sockets
/// or tasks and are interpreted here after each state transition commits.
pub async fn serve(
  handler : @model.Handler,
  addr~ : String,
  on_listen~ : (String) -> Unit = _ => (),
  limits~ : ServerLimits = ServerLimits::default(),
  on_error~ : (ServeError) -> Unit = _ => (),
  compression~ : Bool = false,
) -> Unit raise ServerConfigError {
  limits.validate()
  let listener = @socket.TcpServer(@socket.Addr::parse(addr)) catch {
    _ => raise @config.Bind(detail="could not bind server address")
  }
  defer listener.close()
  run_listener(listener, handler, on_listen, limits, on_error, compression)
}

///|
async fn run_listener(
  listener : @socket.TcpServer,
  handler : @model.Handler,
  on_listen : (String) -> Unit,
  limits : ServerLimits,
  on_error : (ServeError) -> Unit,
  compression : Bool,
) -> Unit raise ServerConfigError {
  let state = ServerState::new()
  let clock = @runtime.AsyncClock::new()
  let timer = @runtime.ClockTimer::new(clock~)
  let coordination = @runtime.RuntimeCoordination::new()
  on_listen(listener.addr.to_string())
  @async.with_task_group(outer => {
    let worker = outer.spawn(allow_failure=true, () => {
      @async.protect_from_cancel(() => {
        @async.with_task_group(group => {
          let alive = Ref(true)
          group.add_defer(() => alive.val = false)
          let background = (work : async () -> Unit) => {
            if alive.val {
              state.next_id += 1L
              let id = state.next_id
              state.background[id] = None
              ignore(state.step(BackgroundStarted(id)))
              let task = group.spawn(() => {
                defer {
                  state.background.remove(id)
                  ignore(state.step(BackgroundFinished(id)))
                }
                work() catch {
                  error => report(error, on_error)
                }
              })
              if state.background.contains(id) {
                state.background[id] = Some(task)
                if state.control.phase is @control.Stopped {
                  task.cancel()
                }
              }
            }
          }
          let acceptor = group.spawn(allow_failure=true, () => {
            while !state.control.stopping() {
              while state.control.connections.length() >= limits.max_connections &&
                    !state.control.stopping() {
                state.changed.wait()
              }
              if state.control.stopping() {
                break
              }
              let (tcp, peer) = listener.accept() catch {
                _ => {
                  if !state.step(AcceptFailed) {
                    break
                  }
                  raise @config.Accept(detail="listener accept failed")
                }
              }
              state.next_id += 1L
              let id = state.next_id
              let wire = Wire::new(
                @socket_conn.from_tcp(tcp),
                clock~,
                timer~,
                coordination~,
              )
              let connection = Connection::{
                session: @engine.Connection::new(wire, activity=busy => {
                  ignore(state.step(Activity(id, busy)))
                }),
                task: None,
              }
              state.connections[id] = connection
              ignore(state.step(Accepted(id)))
              if !state.control.connections.contains(id) {
                state.connections.remove(id)
                continue
              }
              let task = group.spawn(() => {
                defer wire.close()
                defer {
                  state.connections.remove(id)
                  ignore(state.step(Finished(id)))
                }
                @engine.exchange(
                  connection.session,
                  peer.to_string(),
                  listener.addr.to_string(),
                  handler,
                  limits,
                  () => state.control.stopping(),
                  on_error,
                  compression,
                  Some(background),
                ) catch {
                  error => report(error, on_error)
                }
              })
              connection.task = Some(task)
              // A synchronous completion may already have removed this ID.
              if state.control.stopping() && !connection.session.control.busy {
                task.cancel()
              }
            }
          })
          state.stop_accept = Some(() => {
            acceptor.cancel()
            listener.close()
          })
          acceptor.wait() catch {
            @async.WaitedTaskAlreadyCancelled =>
              if !state.control.stopping() {
                raise @config.Accept(detail="accept task cancelled")
              }
            error => raise error
          }
        })
      })
    })
    let result = @async.handle_cancellation(() => worker.wait())
    if result is None {
      @async.protect_from_cancel(() => {
        ignore(state.step(Stop))
        let drained = @async.with_timeout_opt(limits.drain_ms, () => {
          worker.wait()
        }) catch {
          _ => Some(())
        }
        if drained is None {
          ignore(state.step(DrainExpired))
          worker.wait() catch {
            _ => ()
          }
        }
      })
      @async.pause()
    }
  }) catch {
    @config.Accept(detail~) => raise @config.Accept(detail~)
    _ => raise @config.Accept(detail="server task failed")
  }
}
