///|
async test "lifecycle actions close idle and late sockets and cancel background jobs" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let state = ServerState::new()
  let stops = Ref(0)
  state.stop_accept = Some(() => stops.val += 1)
  @async.with_task_group(group => {
    let cleaned = Ref(0)
    let peer = @socket.Tcp::connect(listener.addr)
    defer peer.close()
    let (tcp, _) = listener.accept()
    let conn = @socketconn.from_tcp(tcp)
    let task = group.spawn(allow_failure=true, () => {
      defer {
        cleaned.val += 1
      }
      @cond_var.Cond().wait()
    })
    state.connections[1L] = { conn, task: Some(task), }
    ignore(state.step(Accepted(1L)))
    ignore(state.step(Stop))
    ignore(state.step(Stop))
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
    assert_eq(conn.read(max_len=1), None)
    assert_eq(cleaned.val, 1)
    assert_eq(stops.val, 1)
    ignore(state.step(Finished(1L)))
    let late = @socket.Tcp::connect(listener.addr)
    defer late.close()
    let (tcp, _) = listener.accept()
    let conn = @socketconn.from_tcp(tcp)
    state.connections[2L] = { conn, task: None, }
    ignore(state.step(Accepted(2L)))
    assert_eq(conn.read(max_len=1), None)
    assert_false(state.control.connections.contains(2L))
    let background = group.spawn(allow_failure=true, () => {
      defer {
        cleaned.val += 1
      }
      @cond_var.Cond().wait()
    })
    state.background[3L] = Some(background)
    ignore(state.step(BackgroundStarted(3L)))
    assert_false(state.control.drained())
    ignore(state.step(DrainExpired))
    background.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
    assert_eq(cleaned.val, 2)
    ignore(state.step(BackgroundFinished(3L)))
    assert_true(state.control.drained())
    assert_false(state.step(AcceptFailed))
    assert_true(ServerState::new().step(AcceptFailed))
  })
}

///|
async test "a real accept failure raises ListenError Accept" {
  @async.with_timeout(1000, () => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    try
      run_listener(
        listener,
        _ => @mttp.Response::new(204),
        _ => listener.close(),
        @h1server.ServerLimits::default(),
        _ => (),
      )
    catch {
      Accept(..) => ()
      error => raise error
    } noraise {
      _ => fail("accept failure lost")
    }
  })
}
