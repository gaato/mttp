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
/// Upgraded connections retain their admission slots until their callback
/// ends; the stopping probe and drain deadline apply to them too.
/// `auto_date` adds Date to responses without one; set it to false when an
/// upstream server owns that field. It is passed to `h1server.serve_conn`.
pub async fn serve(
  handler : @mttp_core.Handler,
  addr~ : String,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  auto_date~ : Bool = true,
  on_listen~ : (String) -> Unit = _ => (),
  on_error~ : (@mttp_core.TransportError) -> Unit = _ => (),
) -> Unit raise ListenError {
  serve_conns(
    accepted => {
      let response_finished = Ref(false)
      @h1server.serve_conn(
        accepted.conn,
        request => {
          response_finished.val = false
          (accepted.activity)(true)
          lease(handler(request))
        },
        clock=accepted.clock,
        timer=accepted.timer,
        coordination=accepted.coordination,
        scheme="http",
        limits~,
        auto_date~,
        peer=accepted.peer,
        authority=accepted.authority,
        on_error=error => {
          // A refusal can write a response before invoking the handler.
          // Let that response share the shutdown grace.
          (accepted.activity)(true)
          on_error(error)
        },
        on_response_complete=() => response_finished.val = true,
        stopping=() => {
          // Commit idle at the next-request checkpoint, after the final
          // write/drain and the peer monitor have finished.
          if response_finished.val {
            (accepted.activity)(false)
          }
          (accepted.stopping)()
        },
        background=accepted.background,
      ) catch {
        _ =>
          on_error(
            @mttp_core.TransportError(
              kind=Invalid,
              phase=Unknown,
              detail="validated server limits refused",
            ),
          )
      }
    },
    addr~,
    limits~,
    on_listen~,
    on_error~,
  )
}

///|
/// A connection `serve_conns` accepted, with what its session needs.
pub struct Accepted {
  /// The connection; the session owns it and closes it, and `serve_conns`
  /// closes it too once the session returns.
  conn : &@rt.Conn
  /// The client's address, `host:port`.
  peer : String
  /// The listener's address, `host:port`.
  authority : String
  clock : &@rt.Clock
  timer : &@rt.Timer
  coordination : &@rt.Coordination
  /// Whether the server is stopping. A session looks at it between
  /// exchanges and ends, or tells its peer to go away, when it is true.
  stopping : () -> Bool
  /// Marks the connection busy (`true`) or idle (`false`). At stop an idle
  /// connection is closed at once; a busy one gets `drain_ms` to finish.
  /// A connection starts idle.
  activity : (Bool) -> Unit
  /// Runs work outside the connection's task; stop gives it `drain_ms` too,
  /// then cancels it.
  background : (async () -> Unit) -> Unit
  /// Where the session reports its connection's failures.
  on_error : (@mttp_core.TransportError) -> Unit
}

///|
/// Listens on `addr` as `serve` does, with its admission bound and graceful
/// stop, and runs `session` for each accepted connection: a protocol of the
/// caller's own on the server's lifecycle, such as HTTP/2 over a TLS
/// session (gaato/mttp_ng). `serve` is `serve_conns` with an HTTP/1
/// session. `limits` gives `max_connections` and `drain_ms`; the session
/// applies the rest as its protocol has them.
pub async fn serve_conns(
  session : async (Accepted) -> Unit,
  addr~ : String,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  on_listen~ : (String) -> Unit = _ => (),
  on_error~ : (@mttp_core.TransportError) -> Unit = _ => (),
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
  run_listener(listener, session, on_listen, limits, on_error)
}

///|
async fn run_listener(
  listener : @socket.TcpServer,
  session : async (Accepted) -> Unit,
  on_listen : (String) -> Unit,
  limits : @h1server.ServerLimits,
  on_error : (@mttp_core.TransportError) -> Unit,
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
                        @mttp_core.TransportError(..) as original => original
                        _ =>
                          @mttp_core.TransportError(
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
              let task = group.spawn(() => {
                defer conn.close()
                defer {
                  state.connections.remove(id)
                  ignore(state.step(Finished(id)))
                }
                session({
                  conn,
                  peer: peer.to_string(),
                  authority: listener.addr.to_string(),
                  clock,
                  timer,
                  coordination,
                  stopping: () => state.control.stopping(),
                  activity: busy => ignore(state.step(Activity(id, busy))),
                  background,
                  on_error,
                })
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
