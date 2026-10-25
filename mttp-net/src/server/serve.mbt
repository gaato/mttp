///|
priv struct Connection {
  wire : Wire
  mut task : @async.Task[Unit]?
  mut busy : Bool
}

///|
priv struct ServerState {
  mut stopping : Bool
  connections : Map[Int32, Connection]
  changed : @cond_var.Cond
  mut stop_accept : (() -> Unit)?
  background : Map[Int32, @async.Task[Unit]?]
}

///|
/// Serves bounded HTTP/1 connections. Cancellation stops accepting and allows
/// active exchanges to finish within drain_ms, then closes and cancels them.
/// Configuration and bind failures are raised; connection failures go to
/// on_error. Compression is opt-in and preserves duplicate response fields.
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
    _ => raise Bind(detail="could not bind server address")
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
  let state = ServerState::{
    stopping: false,
    connections: {},
    changed: @cond_var.Cond(),
    stop_accept: None,
    background: {},
  }
  on_listen(listener.addr.to_string())
  @async.with_task_group(outer => {
    let worker = outer.spawn(
      () => {
        @async.protect_from_cancel(() => {
          @async.with_task_group(group => {
            let alive = Ref(true)
            group.add_defer(() => alive.val = false)
            let background = (work : async () -> Unit) => {
              if alive.val {
                let mut id = 0
                while state.background.contains(id) {
                  id += 1
                }
                state.background[id] = None
                let task = group.spawn(() => {
                  defer state.background.remove(id)
                  work() catch {
                    error => report(error, on_error)
                  }
                })
                if state.background.contains(id) {
                  state.background[id] = Some(task)
                }
              }
            }
            let acceptor = group.spawn(
              () => {
                while !state.stopping {
                  while state.connections.length() >= limits.max_connections &&
                        !state.stopping {
                    state.changed.wait()
                  }
                  if state.stopping {
                    break
                  }
                  let (tcp, peer) = listener.accept() catch {
                    _ => {
                      if state.stopping {
                        break
                      }
                      raise Accept(detail="listener accept failed")
                    }
                  }
                  let wire = Wire::{ tcp, pending: b"", closed: false, }
                  let connection = Connection::{
                    wire,
                    task: None,
                    busy: false,
                  }
                  let mut id = 0
                  while state.connections.contains(id) {
                    id += 1
                  }
                  state.connections[id] = connection
                  connection.task = Some(
                    group.spawn(() => {
                      defer wire.close()
                      defer {
                        state.connections.remove(id)
                        state.changed.broadcast()
                      }
                      exchange(
                        connection,
                        peer.to_string(),
                        listener.addr.to_string(),
                        handler,
                        limits,
                        state,
                        on_error,
                        compression,
                        background,
                      ) catch {
                        error => report(error, on_error)
                      }
                    }),
                  )
                }
              },
              allow_failure=true,
            )
            // Closing a listener does not wake an accept already parked in this
            // runtime; cancel that task separately while leaving exchanges alive.
            state.stop_accept = Some(() => acceptor.cancel())
            acceptor.wait() catch {
              @async.WaitedTaskAlreadyCancelled =>
                if !state.stopping {
                  raise Accept(detail="accept task cancelled")
                }
              error => raise error
            }
          })
        })
      },
      allow_failure=true,
    )
    let result = @async.handle_cancellation(() => worker.wait())
    if result is None {
      @async.protect_from_cancel(() => {
        state.stopping = true
        if state.stop_accept is Some(stop) {
          stop()
        }
        listener.close()
        state.changed.broadcast()
        for _, connection in state.connections.copy() {
          if !connection.busy {
            connection.wire.close()
            if connection.task is Some(task) {
              task.cancel()
            }
          }
        }
        let drained = @async.with_timeout_opt(limits.drain_ms, () => {
          worker.wait()
        }) catch {
          _ => Some(())
        }
        if drained is None {
          for _, connection in state.connections.copy() {
            connection.wire.close()
            if connection.task is Some(task) {
              task.cancel()
            }
          }
          for _, task in state.background.copy() {
            if task is Some(task) {
              task.cancel()
            }
          }
          worker.wait() catch {
            _ => ()
          }
        }
      })
      @async.pause()
    }
  }) catch {
    Accept(detail~) => raise Accept(detail~)
    _ => raise Accept(detail="server task failed")
  }
}
