///|
fn ConnSession::on_head(
  self : ConnSession,
  head : @frame.FrameHead,
) -> Unit raise WsError {
  self.head = Some(head)
  self.control_buffer.clear()
  if !self.closing.data_allowed() {
    return
  }
  if head.length == 0L {
    if self.empty_frames >= self.limits.max_empty_frames {
      raise protocol("empty frame limit")
    }
    self.empty_frames += 1
  } else {
    self.empty_frames = 0
  }
  let kind = match head.opcode {
    Text => Some(@control.WsData::Text)
    Binary => Some(@control.WsData::Binary)
    Continuation => None
    _ => return
  }
  if head.opcode is Continuation && head.rsv1 {
    raise protocol("RSV1 on continuation")
  }
  let was_idle = self.assembly is Idle
  guard self.assembly.data(kind, fin=head.fin) is Some((assembly, kind)) else {
    raise protocol("invalid continuation order")
  }
  self.assembly = assembly
  self.kind = kind
  if was_idle {
    self.compressed = head.rsv1
    self.validator = @frame.Utf8Validator::new()
    self.buffer.clear()
  }
}

///|
fn ConnSession::on_payload(
  self : ConnSession,
  bytes : Bytes,
) -> Unit raise WsError {
  guard self.head is Some(head) else { raise protocol("payload without head") }
  if head.opcode is Close ||
    (self.closing.data_allowed() && head.opcode is (Ping | Pong)) {
    self.control_buffer.append(bytes.to_array())
  } else if self.closing.data_allowed() {
    let limit = self.limits.max_message_bytes
    if limit < 0 || bytes.length() > limit - self.buffer.length() {
      raise WsError(kind=TooLarge(limit~), detail="wire message limit")
    }
    if !self.compressed && self.kind is Text && !self.validator.push(bytes) {
      raise WsError(
        kind=Closed({ code: InvalidPayload, reason: "", }),
        detail="invalid text UTF-8",
      )
    }
    self.buffer.append(bytes.to_array())
  }
}

///|
async fn ConnSession::on_end(self : ConnSession) -> Unit raise WsError {
  guard self.head is Some(head) else { raise protocol("end without head") }
  self.head = None
  let payload = Bytes::from_array(self.control_buffer)
  match head.opcode {
    Close => {
      let close = CloseFrame::parse(payload)
      self.close_frame = close
      self.closing = self.closing.receive()
      self.notify()
      self.control(Close, payload)
      self.drop()
    }
    Ping =>
      if self.closing.data_allowed() {
        self.pong_drain = true
        self.offer_pong(payload)
      }
    Pong => ()
    _ =>
      if self.closing.data_allowed() && head.fin {
        let raw = Bytes::from_array(self.buffer)
        let decoded = match self.extension {
          Some(extension) =>
            extension.decode(
              raw,
              rsv1=self.compressed,
              max_bytes=self.limits.max_message_bytes,
            )
          None => raw
        }
        if decoded.length() > self.limits.max_message_bytes {
          raise WsError(
            kind=TooLarge(limit=self.limits.max_message_bytes),
            detail="decoded message limit",
          )
        }
        if self.kind is Text {
          let validator = @frame.Utf8Validator::new()
          if !validator.push(decoded) || !validator.finish() {
            raise WsError(
              kind=Closed({ code: InvalidPayload, reason: "", }),
              detail="incomplete text UTF-8",
            )
          }
          self.ready = Some(Text(@utf8.decode_lossy(decoded)))
        } else {
          self.ready = Some(Binary(decoded))
        }
        self.buffer.clear()
      }
  }
}

///|
/// State and bytes are committed before every suspension; cancellation only
/// discards the waiter, not partial parser state or a completed message.
async fn ConnSession::read_message(self : ConnSession) -> Unit raise WsError {
  while self.ready is None && !(self.closing.phase is Closed) {
    let event = self.next_event()
    match event {
      Some(Head(head)) => self.on_head(head)
      Some(Payload(bytes)) => self.on_payload(bytes)
      Some(End) => self.on_end()
      None => self.pull_input()
    }
  }
  // A small/one-byte transport may still be writing the Pong after the
  // message became ready. Both peers must keep draining controls while the
  // protected writes finish, rather than both joining blocked writers.
  if self.ready is Some(_) && self.pong_drain {
    self.drain_pongs()
  }
}

///|
async fn ConnSession::pull_input(self : ConnSession) -> Unit raise WsError {
  let bytes = self.read_input() catch {
    cause =>
      raise WsError(kind=Transport(cause), detail="WebSocket read failed")
  }
  guard bytes is Some(bytes) else {
    self.abort()
    raise self.error()
  }
  if bytes.is_empty() {
    raise protocol("empty connection read")
  }
  self.feed_input(bytes)
  self.life = self.life.received(self.clock.now_unix_ms())
  self.notify()
}

///|
fn ConnSession::feed_input(self : ConnSession, bytes : Bytes) -> Unit {
  self.buffered_wire += bytes.length()
  self.parser.feed(bytes)
}

///|
/// Count raw bytes not yet reported as complete headers/payloads. Partial
/// headers remain counted, so finishing our Pong cannot abandon the peer's
/// half-written control frame. A deferred data head is delivered only once.
fn ConnSession::next_event(self : ConnSession) -> @frame.Event? raise WsError {
  if self.deferred_head is Some(head) {
    self.deferred_head = None
    return Some(Head(head))
  }
  let event = self.parser.next() catch {
    @frame.FrameError(kind=TooLarge(limit~), ..) =>
      raise WsError(kind=TooLarge(limit~), detail="frame limit")
    _ => raise protocol("invalid WebSocket frame")
  }
  match event {
    Some(Head(head)) => {
      let extended = if head.length < 126L {
        0
      } else if head.length <= 65535L {
        2
      } else {
        8
      }
      self.buffered_wire -= 2 + extended + (if head.masked { 4 } else { 0 })
    }
    Some(Payload(bytes)) => self.buffered_wire -= bytes.length()
    _ => ()
  }
  event
}

///|
/// Keep input live while joining our protected Pong, and finish any peer
/// control frame already started: its write may still be waiting on us even
/// after our own write ended. Leave the next data/Close head for the next
/// receive rather than overwrite the already committed application message.
async fn ConnSession::drain_pongs(self : ConnSession) -> Unit raise WsError {
  while !(self.closing.phase is Closed) &&
        (
          self.pending_pong is Some(_) ||
          !(self.pong_progress is Idle) ||
          self.head is Some(_) ||
          self.buffered_wire > 0
        ) {
    match self.next_event() {
      Some(Head(head)) => {
        if !(head.opcode is (Ping | Pong)) {
          self.deferred_head = Some(head)
          if self.pending_pong is Some(_) || !(self.pong_progress is Idle) {
            self.read_during_pong(finish=true)
          }
          return
        }
        self.on_head(head)
      }
      Some(Payload(bytes)) => self.on_payload(bytes)
      Some(End) => self.on_end()
      None => {
        if self.pong_read_ahead.is_empty() &&
          (self.pending_pong is Some(_) || !(self.pong_progress is Idle)) {
          self.read_during_pong()
          if self.pong_read_ahead.is_empty() {
            continue
          }
        }
        self.pull_input()
      }
    }
  }
}

///|
async fn ConnSession::receive(self : ConnSession) -> Unit noraise {
  self.read_message() catch {
    error => {
      let code = match error {
        WsError(kind=TooLarge(_), ..) => MessageTooBig
        WsError(kind=Closed({ code: InvalidPayload, .. }), ..) => InvalidPayload
        _ => ProtocolError
      }
      if !(self.closing.phase is Closed) {
        self.fail(error, code)
      }
    }
  }
}

///|
impl Session for ConnSession with fn recv(self) {
  if self.reading {
    raise protocol("concurrent WebSocket recv")
  }
  if self.closing.phase is Closed {
    raise self.error()
  }
  self.reading = true
  defer {
    self.reading = false
    self.notify()
  }
  self.coordination.supervise(primary=() => self.receive(), monitor=() => {
    self.watch()
  }) catch {
    cause => {
      self.abort()
      raise WsError(
        kind=Transport(cause),
        detail="WebSocket coordination failed",
      )
    }
  }
  self.flush_pong()
  if self.ready is Some(message) {
    self.ready = None
    self.pong_drain = false
    return message
  }
  raise self.error()
}

///|
impl Session for ConnSession with fn close(self, frame) {
  if self.closing.phase is Closed {
    return
  }
  if self.close_started {
    ignore(
      self.timer.within(self.limits.close_timeout_ms, () => self.closed.wait()),
    )
    self.abort()
    return
  }
  self.close_started = true
  self.ready = None
  self.closing = self.closing.request()
  self.notify()
  // Every exit, including caller cancellation, disposes of the connection.
  defer self.drop()
  let payload = frame.encode() catch {
    _ => {
      self.abort()
      return
    }
  }
  ignore(
    self.timer.within(self.limits.close_timeout_ms, () => {
      self.emit(Close, payload) catch {
        _ => self.abort()
      }
      while !(self.closing.phase is Closed) {
        if self.reading {
          let changed = self.changed
          changed.wait()
        } else {
          self.reading = true
          defer {
            self.reading = false
            self.notify()
          }
          self.receive()
        }
      }
    }),
  )
}
