///|
async test "lifecycle actions close idle and late connections and join background cancellation" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let peer = @socket.Tcp::connect(listener.addr)
  defer peer.close()
  let (tcp, _) = listener.accept()
  let wire = test_wire(tcp)
  let state = ServerState::new()
  let stopped = Ref(0)
  state.stop_accept = Some(() => stopped.val += 1)
  @async.with_task_group(group => {
    let cleaned = Ref(0)
    let task = group.spawn(allow_failure=true, () => {
      defer {
        cleaned.val += 1
      }
      @cond_var.Cond().wait()
    })
    state.connections[1L] = {
      session: @engine.Connection::new(wire),
      task: Some(task),
    }
    ignore(state.step(Accepted(1L)))
    ignore(state.step(Stop))
    ignore(state.step(Stop))
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
    assert_true(wire.closed)
    assert_eq(cleaned.val, 1)
    assert_eq(stopped.val, 1)
    ignore(state.step(Finished(1L)))
    let late = @socket.Tcp::connect(listener.addr)
    defer late.close()
    let (tcp, _) = listener.accept()
    let late_wire = test_wire(tcp)
    state.connections[2L] = {
      session: @engine.Connection::new(late_wire),
      task: None,
    }
    ignore(state.step(Accepted(2L)))
    assert_true(late_wire.closed)
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
  })
}
