///|
priv struct HostSession {
  handle : Handle
  limits : @ws.WsLimits
  sending : @semaphore.Semaphore
  mut receiving : Bool
  protocol : String?
}

///|
extend HostSession with @ws.Session::{close, abort}

///|
fn new_session(
  socket : Socket,
  limits : @ws.WsLimits,
  protocol : String?,
) -> HostSession {
  HostSession::{
    handle: attach(
      socket,
      limits.max_message_bytes.max(0),
      limits.max_empty_frames.max(0),
    ),
    limits,
    sending: @semaphore.Semaphore(1),
    receiving: false,
    protocol,
  }
}

///|
/// Host WebSocket client bridge used by ws.connect. Headers require Bun or
/// Workers; bounded queues and host controls are described in hosts/README.md.
pub async fn websocket_connect(
  url : String,
  protocols : Array[String],
  headers : @mttp_core.Headers,
  limits : @ws.WsLimits,
) -> &@ws.Session raise @ws.WsError {
  let pairs = headers
    .iter()
    .map(pair => FixedArray::from_array([pair.0, pair.1]))
    .collect()
  let controller = @js_async.AbortController::new()
  let handle = @async.with_timeout(limits.send_timeout_ms.max(1), () => {
    open_socket(
      url,
      FixedArray::from_array(protocols),
      FixedArray::from_array(pairs),
      socket => {
        attach(
          socket,
          limits.max_message_bytes.max(0),
          limits.max_empty_frames.max(0),
        )
      },
      controller.signal(),
    ).wait(abort_controller=controller)
  }) catch {
    error =>
      raise @ws.WsError(
        kind=Handshake(status=0),
        detail="host WebSocket handshake failed: \{error}",
      )
  }
  let protocol = handle.protocol()
  HostSession::{
    handle,
    limits,
    sending: @semaphore.Semaphore(1),
    receiving: false,
    protocol: if protocol.is_empty() {
      None
    } else {
      Some(protocol)
    },
  }
}

///|
impl @ws.Session for HostSession with fn recv(self) {
  if self.receiving {
    raise @ws.WsError(kind=Protocol, detail="concurrent recv")
  }
  self.receiving = true
  defer {
    self.receiving = false
  }
  let controller = @js_async.AbortController::new()
  self.handle.wait(controller.signal()).wait(abort_controller=controller) catch {
    _ => raise @ws.WsError(kind=Protocol, detail="host receive failed")
  }
  let event = self.handle.take()
  match event.kind {
    0 => Text(event.text)
    1 => Binary(event.data)
    3 =>
      raise @ws.WsError(
        kind=TooLarge(limit=self.limits.max_message_bytes),
        detail=event.reason,
      )
    4 =>
      raise @ws.WsError(
        kind=Closed({
          code: @ws.CloseCode::from_int(event.code),
          reason: event.reason,
        }),
        detail=event.reason,
      )
    5 =>
      raise @ws.WsError(
        kind=Transport(
          @mttp_core.TransportError(
            kind=Network,
            phase=Body,
            detail=event.reason,
          ),
        ),
        detail=event.reason,
      )
    _ =>
      raise @ws.WsError(
        kind=Closed({
          code: @ws.CloseCode::from_int(event.code),
          reason: event.reason,
        }),
        detail="host WebSocket closed",
      )
  }
}

///|
impl @ws.Session for HostSession with fn send(self, message) {
  let size = match message {
    Text(text) => @utf8.encode(text).length()
    Binary(data) => data.length()
  }
  if size > self.limits.max_message_bytes {
    raise @ws.WsError(
      kind=TooLarge(limit=self.limits.max_message_bytes),
      detail="outbound message limit",
    )
  }
  let mut done = false
  defer (if !done { self.handle.abort() })
  @async.with_timeout(self.limits.send_timeout_ms.max(1), () => {
    self.sending.acquire()
    defer self.sending.release()
    let failure = match message {
      Text(text) => self.handle.send(text, b"", false).wait()
      Binary(data) => self.handle.send("", data, true).wait()
    }
    if failure != "" {
      raise @ws.WsError(
        kind=Closed({ code: Abnormal, reason: "", }),
        detail=failure,
      )
    }
    while self.handle.buffered().wait() > 0 {
      if self.handle.state() != 1 {
        raise @ws.WsError(
          kind=Closed({ code: Abnormal, reason: "", }),
          detail="closed during send",
        )
      }
      @async.sleep(1)
    }
  }) catch {
    @ws.WsError(..) as error => raise error
    _ =>
      raise @ws.WsError(
        kind=Timeout(ms=self.limits.send_timeout_ms),
        detail="host send deadline",
      )
  }
  done = true
}

///|
impl @ws.Session for HostSession with fn close(self, frame) {
  defer self.handle.abort()
  ignore(frame.encode() catch { _ => return })
  self.handle.close(frame.code.to_int(), frame.reason)
  @async.with_timeout(self.limits.close_timeout_ms.max(1), () => {
    while self.handle.state() != 3 {
      @async.sleep(1)
    }
  }) catch {
    _ => ()
  }
}

///|
impl @ws.Session for HostSession with fn abort(self) {
  self.handle.abort()
}

///|
impl @ws.Session for HostSession with fn subprotocol(self) {
  self.protocol
}
