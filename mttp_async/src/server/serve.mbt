///|
/// Listener failures. Configuration is checked before binding; connection
/// and background failures go to `on_error` instead. Frozen at release.
#derive(Debug)
pub(all) suberror ListenError {
  Config(@h1server.ServerConfigError)
  Bind(detail~ : String)
  Accept(detail~ : String)
}

///|
/// Formats a listener failure for diagnostics.
pub extend ListenError with @debug.Debug::{to_repr}

///|
/// Serves HTTP/1 on TCP, with bounded connection admission and graceful
/// shutdown on cancellation. `on_listen` receives the actual bound address.
/// Stop closes idle connections and the listener, lets active responses and
/// background jobs finish for `limits.drain_ms`, then cancels and joins them.
/// The listener sets `SO_REUSEADDR`, so a restart can bind the port while the
/// previous process's connections are in TIME-WAIT.
pub async fn serve(
  handler : @mttp.Handler,
  addr~ : String,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  on_listen~ : (String) -> Unit = _ => (),
  on_error~ : (@mttp.TransportError) -> Unit = _ => (),
) -> Unit raise ListenError {
  limits.validate() catch {
    error => raise Config(error)
  }
  let parsed = @socket.Addr::parse(addr) catch {
    // InvalidAddr carries no text of its own; say what is expected instead.
    @socket.InvalidAddr =>
      raise Bind(
        detail="invalid address \{Repr(addr)}: expected an IP address and port, such as 127.0.0.1:8080 or [::]:8080",
      )
    error => raise Bind(detail="invalid address \{Repr(addr)}: \{error}")
  }
  // SO_REUSEADDR, as Go and Node set it: a restart can bind while the old
  // process's connections sit in TIME-WAIT. It never lets two listeners share
  // a port on Linux, and core leaves it off on Windows (see the README).
  let listener = @socket.TcpServer(parsed, reuse_addr=true) catch {
    error => raise Bind(detail="could not bind \{addr}: \{error}")
  }
  defer listener.close()
  run_listener(listener, handler, on_listen, limits, on_error)
}

///|
async fn run_listener(
  listener : @socket.TcpServer,
  handler : @mttp.Handler,
  on_listen : (String) -> Unit,
  limits : @h1server.ServerLimits,
  on_error : (@mttp.TransportError) -> Unit,
) -> Unit raise ListenError {
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
                  error =>
                    on_error(
                      match error {
                        @mttp.TransportError(..) as original => original
                        _ =>
                          @mttp.TransportError(
                            kind=Network,
                            phase=Unknown,
                            detail="background job failed",
                          )
                      },
                    )
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
              // One acceptor waits for capacity before accept: no accepted
              // socket queue, and no task/slot allocated for queued clients.
              while state.control.connections.length() >= limits.max_connections &&
                    !state.control.stopping() {
                state.changed.wait()
              }
              if state.control.stopping() {
                break
              }
              let (tcp, peer) = listener.accept() catch {
                error => {
                  if !state.step(AcceptFailed) {
                    break
                  }
                  raise Accept(detail="listener accept failed: \{error}")
                }
              }
              state.next_id += 1L
              let id = state.next_id
              let conn = @socketconn.from_tcp(tcp)
              let connection = Connection::{ conn, task: None, }
              state.connections[id] = connection
              ignore(state.step(Accepted(id)))
              if !state.control.connections.contains(id) {
                state.connections.remove(id)
                continue
              }
              let response_finished = Ref(false)
              let task = group.spawn(() => {
                defer conn.close()
                defer {
                  state.connections.remove(id)
                  ignore(state.step(Finished(id)))
                }
                @h1server.serve_conn(
                  conn,
                  request => {
                    response_finished.val = false
                    ignore(state.step(Activity(id, true)))
                    lease(handler(request), request.meth, () => {
                      response_finished.val = true
                    })
                  },
                  clock~,
                  timer~,
                  coordination~,
                  scheme="http",
                  limits~,
                  peer=peer.to_string(),
                  authority=listener.addr.to_string(),
                  on_error=error => {
                    // A refusal can write a response before invoking the
                    // handler. Let that response share the shutdown grace.
                    ignore(state.step(Activity(id, true)))
                    on_error(error)
                  },
                  stopping=() => {
                    // Stream EOF can close its source before the final wire
                    // write. Commit idle only at the engine's next-request
                    // checkpoint, after all response writes have finished.
                    if response_finished.val {
                      ignore(state.step(Activity(id, false)))
                    }
                    state.control.stopping()
                  },
                  background~,
                ) catch {
                  _ =>
                    on_error(
                      @mttp.TransportError(
                        kind=Invalid,
                        phase=Unknown,
                        detail="validated server limits refused",
                      ),
                    )
                }
              })
              connection.task = Some(task)
              if state.control.stopping() &&
                !state.control.connections.get(id).unwrap_or(false) {
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
                raise Accept(detail="accept task cancelled")
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
    Accept(detail~) => raise Accept(detail~)
    error => raise Accept(detail="server task failed: \{error}")
  }
}
