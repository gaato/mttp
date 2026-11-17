///|
extend HostSession with @ws.Session::{recv, send, subprotocol}

///|
extern "js" fn check_socket_callback_scope(
  make : (Socket) -> Handle,
  send : (Handle) -> @js_async.Promise[String],
  buffered : (Handle) -> @js_async.Promise[Int32],
  wait : (Handle, @js_async.AbortSignal) -> @js_async.Promise[Unit],
) -> @js_async.Promise[Unit] =
  #| async (make, send, buffered, wait) => {
  #|   const {AsyncLocalStorage} = await import('node:async_hooks');
  #|   const scope = new AsyncLocalStorage();
  #|   const owner = () => {
  #|     if (scope.getStore() !== 'socket') throw new Error('callback escaped the socket scope');
  #|   };
  #|   const socket = Object.assign(new EventTarget(), {readyState: 1, protocol: '', send() { owner(); }});
  #|   Object.defineProperty(socket, 'bufferedAmount', {get() { owner(); return 0; }});
  #|   const handle = scope.run('socket', () => make(socket));
  #|   // A scheduler turn from a different request subscribes to each operation.
  #|   const observe = operation => scope.run('other request', () => new Promise((resolve, reject) => {
  #|     operation().then(value => {
  #|       try { owner(); resolve(value); } catch (error) { reject(error); }
  #|     }, error => {
  #|       try { owner(); reject(error); } catch (failure) { reject(failure); }
  #|     });
  #|   }));
  #|   try {
  #|     await observe(() => send(handle));
  #|     await observe(() => buffered(handle));
  #|     const controller = new AbortController();
  #|     const pending = observe(() => wait(handle, controller.signal));
  #|     await new Promise(resolve => setImmediate(resolve));
  #|     scope.run('socket', () => socket.dispatchEvent(new MessageEvent('message', {data: 'ready'})));
  #|     await pending;
  #|     // The already-readable path must enter the owner too.
  #|     await observe(() => wait(handle, controller.signal));
  #|     handle.queue.length = 0; handle.bytes = 0;
  #|     const cancelled = observe(() => wait(handle, controller.signal));
  #|     await new Promise(resolve => setImmediate(resolve));
  #|     scope.run('other request', () => controller.abort());
  #|     try { await cancelled; throw new Error('wait did not reject'); }
  #|     catch (error) { if (error.name !== 'AbortError') throw error; }
  #|   } finally { handle.detach(); }
  #| }

///|
async test "WebSocket operations and wait callbacks stay in the socket scope across scheduler callers" {
  check_socket_callback_scope(
    socket => attach(socket, 32, 4),
    handle => handle.send("hello", b"", false),
    handle => handle.buffered(),
    (handle, signal) => handle.wait(signal),
  ).wait()
}

///|
extern "js" fn fake_socket() -> Socket =
  #| () => Object.assign(new EventTarget(), {readyState: 1, bufferedAmount: 0, protocol: 'echo',
  #|   send(data) { this.sent = data; }, close(code, reason) {
  #|     this.closeCode = code; this.closeArgs = [...arguments]; this.readyState = 3;
  #|     const event = new Event('close'); Object.assign(event, {code, reason}); this.dispatchEvent(event);
  #|   }})

///|
extern "js" fn emit(socket : Socket, text : String, binary : Bool) -> Unit =
  #| (socket, text, binary) => socket.dispatchEvent(new MessageEvent('message', {data: binary ? new TextEncoder().encode(text) : text}))

///|
extern "js" fn closed_code(socket : Socket) -> Int32 =
  #| socket => socket.closeCode || 0

///|
extern "js" fn close_arg_count(socket : Socket) -> Int32 =
  #| socket => socket.closeArgs?.length ?? -1

///|
async test "abort requests host close without a status and retains local abnormal closure" {
  let socket = fake_socket()
  let session = new_session(socket, @ws.WsLimits::default(), None)
  emit(socket, "discarded", false)
  session.abort()
  session.abort()
  @async.sleep(1)
  assert_eq(close_arg_count(socket), 0)
  try session.recv() catch {
    @ws.WsError(kind=Closed({ code: Abnormal, .. }), ..) => ()
    _ => fail("lost local abort status")
  } noraise {
    _ => fail("abort retained a queued message")
  }
}

///|
extern "js" fn queued(handle : Handle) -> Int32 =
  #| handle => handle.queue.length

///|
async test "cancelled send aborts with no host status and local abnormal closure" {
  let socket = fake_socket()
  block_drain(socket)
  let session = new_session(socket, @ws.WsLimits::default(), None)
  @async.with_task_group(group => {
    let sender = group.spawn(() => session.send(Text("blocked")))
    @async.sleep(1)
    sender.cancel()
    sender.wait() catch {
      _ => ()
    }
  })
  @async.sleep(1)
  assert_eq(close_arg_count(socket), 0)
  try session.recv() catch {
    @ws.WsError(kind=Closed({ code: Abnormal, .. }), ..) => ()
    _ => fail("cancelled send lost local abnormal closure")
  } noraise {
    _ => fail("cancelled send left the session open")
  }
}

///|
extern "js" fn host_error(socket : Socket) -> Unit =
  #| socket => socket.dispatchEvent(new Event('error'))

///|
async test "inbound bytes and message count fail at one past the bound and release the queue" {
  for binary in [false, true] {
    let socket = fake_socket()
    let limits = {
      ..@ws.WsLimits::default(),
      max_message_bytes: 4,
      max_empty_frames: 2,
    }
    let session = new_session(socket, limits, Some("echo"))
    emit(socket, "é", binary)
    emit(socket, "é", binary)
    emit(socket, "x", binary)
    for _ in 0..<2 {
      try session.recv() catch {
        @ws.WsError(kind=TooLarge(limit=4), ..) => ()
        _ => fail("lost sticky byte-limit failure")
      } noraise {
        _ => fail("accepted overflow")
      }
    }
    assert_eq(closed_code(socket), 1009)
  }
  let socket = fake_socket()
  let handle = attach(socket, 4, 2)
  emit(socket, "", false)
  emit(socket, "", false)
  assert_eq(queued(handle), 2)
  emit(socket, "", false)
  assert_eq(queued(handle), 0)
  assert_eq(handle.take().code, 1008)
  @async.sleep(1)
  assert_eq(closed_code(socket), 1008)
  let socket = fake_socket()
  restrict_close(socket)
  let session = new_session(
    socket,
    { ..@ws.WsLimits::default(), max_message_bytes: 4, },
    None,
  )
  emit(socket, "large", false)
  try session.recv() catch {
    @ws.WsError(kind=TooLarge(limit=4), ..) => ()
    _ => fail("wrong oversized-message failure")
  } noraise {
    _ => fail("accepted large message")
  }
  @async.sleep(1)
  assert_eq(closed_code(socket), 4009)
}

///|
extern "js" fn restrict_close(socket : Socket) -> Unit =
  #| socket => { const close = socket.close.bind(socket); socket.close = (code, reason) => {
  #|   if (code !== 1000 && !(code >= 3000 && code <= 4999)) throw new Error('restricted close code');
  #|   close(code, reason);
  #| }; }

///|
async test "text binary close reason and error map to the portable session" {
  let socket = fake_socket()
  let session = new_session(socket, @ws.WsLimits::default(), Some("echo"))
  assert_eq(session.subprotocol(), Some("echo"))
  emit(socket, "hello", false)
  emit(socket, "bytes", true)
  assert_eq(session.recv(), Text("hello"))
  assert_eq(session.recv(), Binary(b"bytes"))
  session.send(Text("out"))
  session.send(Binary(b"out"))
  session.close({ code: Other(4001), reason: "finished", })
  try session.recv() catch {
    @ws.WsError(kind=Closed({ code: Other(4001), reason: "finished", }), ..) =>
      ()
    _ => fail("lost close frame")
  } noraise {
    _ => fail("expected close")
  }
  let socket = fake_socket()
  let session = new_session(socket, @ws.WsLimits::default(), None)
  host_error(socket)
  try session.recv() catch {
    @ws.WsError(kind=Transport(@mttp_core.TransportError(kind=Network, ..)), ..) =>
      ()
    _ => fail("wrong host error")
  } noraise {
    _ => fail("accepted host error")
  }
}

///|
async test "cancelled receive retains queued messages and concurrent receive is refused" {
  let socket = fake_socket()
  let session = new_session(socket, @ws.WsLimits::default(), None)
  @async.with_task_group(group => {
    let pending = group.spawn(() => session.recv())
    @async.sleep(1)
    try session.recv() catch {
      @ws.WsError(kind=Protocol, ..) => ()
      _ => fail("wrong concurrent recv failure")
    } noraise {
      _ => fail("accepted concurrent receiver")
    }
    pending.cancel()
    emit(socket, "retained", false)
    ignore(pending.wait() catch { _ => Text("") })
    assert_eq(session.recv(), Text("retained"))
  })
  session.abort()
}

///|
extern "js" fn observe_receive(
  operation : @js_async.Promise[Unit],
) -> @js_async.Promise[Unit] =
  #| operation => new Promise((resolve, reject) => operation.then(resolve, reject))

///|
extern "js" fn observe_send(
  operation : @js_async.Promise[String],
) -> @js_async.Promise[String] =
  #| operation => new Promise((resolve, reject) => operation.then(resolve, reject))

///|
async test "send and close waits are bounded and oversized sends do not write" {
  let socket = fake_socket()
  let handle = attach(socket, 4, 2048)
  let waiting = observe_receive(
    handle.wait(@js_async.AbortController().signal()),
  )
  let sent = observe_send(handle.send("ok", b"", false))
  for _ in 0..<1024 {
    emit(socket, "", false)
  }
  for _ in 0..<1024 {
    handle.close(1000, "")
    handle.abort()
  }
  assert_eq(pending_operations(handle), 10)
  waiting.wait()
  ignore(sent.wait())
  let socket = fake_socket()
  let session = new_session(
    socket,
    {
      ..@ws.WsLimits::default(),
      max_message_bytes: 2,
      send_timeout_ms: 5,
      close_timeout_ms: 5,
    },
    None,
  )
  try session.send(Text("big")) catch {
    @ws.WsError(kind=TooLarge(limit=2), ..) => ()
    _ => fail("wrong send size failure")
  } noraise {
    _ => fail("accepted large send")
  }
  block_drain(socket)
  try session.send(Text("ok")) catch {
    @ws.WsError(kind=Timeout(ms=5), ..) => ()
    _ => fail("wrong send timeout")
  } noraise {
    _ => fail("unbounded send")
  }
  @async.sleep(1)
  assert_eq(close_arg_count(socket), 0)
  try session.recv() catch {
    @ws.WsError(kind=Closed({ code: Abnormal, .. }), ..) => ()
    _ => fail("send timeout lost local abnormal closure")
  } noraise {
    _ => fail("send timeout left the session open")
  }
  let socket = fake_socket()
  block_close(socket)
  let session = new_session(
    socket,
    { ..@ws.WsLimits::default(), close_timeout_ms: 5, },
    None,
  )
  session.close({ code: Normal, reason: "", })
}

///|
extern "js" fn pending_operations(handle : Handle) -> Int32 =
  #| handle => handle.operations.length

///|
extern "js" fn block_drain(socket : Socket) -> Unit =
  #| socket => { socket.bufferedAmount = 1; }

///|
extern "js" fn block_close(socket : Socket) -> Unit =
  #| socket => { socket.close = () => {}; }
