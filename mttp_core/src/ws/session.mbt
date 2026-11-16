///|
extend ConnSession with Session::{abort}

///|
/// Starting/Settling involve scheduler bookkeeping only. Queued and Writing
/// may need peer input, so the parser must never wait for their completion.
priv enum PongProgress {
  Idle
  Starting
  Queued
  Writing
  Settling
}

///|
priv struct ConnSession {
  conn : &@rt.Conn
  role : @frame.Role
  clock : &@rt.Clock
  timer : &@rt.Timer
  coordination : &@rt.Coordination
  entropy : (Int32) -> Bytes?
  limits : WsLimits
  extension : &Extension?
  protocol : String?
  parser : @frame.Parser
  lock : SendLock
  mut closing : @control.WsCloseState
  mut close_frame : CloseFrame
  mut failure : WsError?
  mut assembly : @control.WsAssembly
  mut kind : @control.WsData
  mut head : @frame.FrameHead?
  mut compressed : Bool
  mut validator : @frame.Utf8Validator
  buffer : Array[Byte]
  control_buffer : Array[Byte]
  mut empty_frames : Int32
  mut ready : Message?
  mut reading : Bool
  mut close_started : Bool
  mut pending_pong : Bytes?
  mut pong_progress : PongProgress
  mut pong_read_ahead : Bytes
  mut pong_read_error : @mttp_core.TransportError?
  mut buffered_wire : Int32
  mut deferred_head : @frame.FrameHead?
  mut pong_drain : Bool
  mut life : @control.WsLife
  mut changed : &@rt.Signal
  closed : &@rt.Signal
}

///|
/// Takes ownership of conn and pending bytes from the HTTP upgrade. No task is
/// detached: recv (or close when there is no receiver) drives reads and keepalive.
pub fn session_over_conn(
  conn : &@rt.Conn,
  role~ : @frame.Role,
  pending~ : Bytes,
  clock~ : &@rt.Clock,
  timer~ : &@rt.Timer,
  coordination~ : &@rt.Coordination,
  entropy~ : (Int32) -> Bytes?,
  limits~ : WsLimits = WsLimits::default(),
  extension? : &Extension,
  subprotocol? : String,
) -> &Session {
  let parser = @frame.Parser::new(
    role~,
    max_frame_bytes=limits.max_frame_bytes,
    allow_rsv1=extension is Some(_),
  )
  parser.feed(pending)
  ConnSession::{
    conn,
    role,
    clock,
    timer,
    coordination,
    entropy,
    limits,
    extension,
    protocol: subprotocol,
    parser,
    lock: SendLock::new(coordination),
    closing: @control.WsCloseState::new(),
    close_frame: { code: Abnormal, reason: "", },
    failure: None,
    assembly: Idle,
    kind: Binary,
    head: None,
    compressed: false,
    validator: @frame.Utf8Validator::new(),
    buffer: [],
    control_buffer: [],
    empty_frames: 0,
    ready: None,
    reading: false,
    close_started: false,
    pending_pong: None,
    pong_progress: Idle,
    pong_read_ahead: b"",
    pong_read_error: None,
    buffered_wire: pending.length(),
    deferred_head: None,
    pong_drain: false,
    life: Alive(clock.now_unix_ms()),
    changed: coordination.signal(),
    closed: coordination.signal(),
  }
}

///|
fn ConnSession::notify(self : ConnSession) -> Unit {
  let old = self.changed
  self.changed = self.coordination.signal()
  old.notify()
}

///|
fn ConnSession::drop(self : ConnSession) -> Unit {
  self.closing = self.closing.finish()
  self.pending_pong = None
  self.pong_read_ahead = b""
  self.pong_read_error = None
  self.buffered_wire = 0
  self.deferred_head = None
  self.pong_drain = false
  self.ready = None
  self.buffer.clear()
  self.control_buffer.clear()
  self.conn.close()
  self.closed.notify()
  self.notify()
}

///|
fn ConnSession::error(self : ConnSession) -> WsError {
  self.failure.unwrap_or(
    WsError(kind=Closed(self.close_frame), detail="WebSocket closed"),
  )
}

///|
impl Session for ConnSession with fn abort(self) {
  if !(self.closing.phase is Closed) {
    self.close_frame = { code: Abnormal, reason: "", }
    self.drop()
  }
}

///|
impl Session for ConnSession with fn subprotocol(self) {
  self.protocol
}

///|
/// Exactly one write contains the whole immutable frame. A cancelled write may
/// have emitted a prefix, so every unfinished write drops the connection.
async fn ConnSession::write_frame(
  self : ConnSession,
  opcode : @frame.Opcode,
  payload : Bytes,
  rsv1~ : Bool = false,
) -> Unit raise WsError {
  let mask = if self.role is Client {
    match (self.entropy)(4) {
      Some(key) if key.length() == 4 => Some(key)
      _ => {
        self.abort()
        raise protocol("mask entropy unavailable or wrong length")
      }
    }
  } else {
    None
  }
  let header = @frame.encode_head(
    @frame.FrameHead::new(
      fin=true,
      rsv1~,
      opcode~,
      masked=mask is Some(_),
      length=payload.length().to_int64(),
    ),
    mask?,
  ) catch {
    _ => {
      self.abort()
      raise protocol("invalid outgoing frame")
    }
  }
  let payload = match mask {
    Some(key) =>
      @frame.apply_mask(payload, key) catch {
        _ => {
          self.abort()
          raise protocol("invalid mask")
        }
      }
    None => payload
  }
  let mut complete = false
  defer (if !complete { self.abort() })
  self.conn.write(header + payload) catch {
    cause => {
      if self.failure is None {
        self.failure = Some(
          WsError(kind=Transport(cause), detail="WebSocket write failed"),
        )
      }
      raise self.error()
    }
  }
  complete = true
}

///|
async fn ConnSession::emit(
  self : ConnSession,
  opcode : @frame.Opcode,
  payload : Bytes,
  rsv1~ : Bool = false,
) -> Unit raise WsError {
  let ticket = self.lock.enqueue()
  defer self.lock.release(ticket)
  let mut failure : WsError? = None
  let completed = self.timer.within(self.limits.send_timeout_ms, () => {
    ticket.signal.wait()
    try {
      if self.closing.phase is Closed {
        raise self.error()
      }
      if opcode is Close {
        let (state, allowed) = self.closing.send()
        self.closing = state
        if allowed {
          self.write_frame(opcode, payload, rsv1~)
        }
      } else if self.closing.data_allowed() {
        self.write_frame(opcode, payload, rsv1~)
      } else {
        raise self.error()
      }
    } catch {
      error => failure = Some(error)
    }
  })
  if !completed {
    self.failure = Some(
      WsError(
        kind=Timeout(ms=self.limits.send_timeout_ms),
        detail="WebSocket send deadline",
      ),
    )
    self.abort()
    raise self.error()
  }
  if failure is Some(error) {
    raise error
  }
}

///|
impl Session for ConnSession with fn send(self, message) {
  if !self.closing.data_allowed() {
    raise self.error()
  }
  let (opcode, raw) = match message {
    Text(text) => (@frame.Opcode::Text, @utf8.encode(text))
    Binary(bytes) => (@frame.Opcode::Binary, bytes)
  }
  if raw.length() > self.limits.max_message_bytes ||
    self.limits.max_message_bytes < 0 {
    raise WsError(
      kind=TooLarge(limit=self.limits.max_message_bytes),
      detail="outgoing message limit",
    )
  }
  let (payload, rsv1) = match self.extension {
    Some(extension) => extension.encode(raw)
    None => (raw, false)
  }
  if payload.length() > self.limits.max_frame_bytes ||
    self.limits.max_frame_bytes < 0 {
    raise WsError(
      kind=TooLarge(limit=self.limits.max_frame_bytes),
      detail="outgoing frame limit",
    )
  }
  if payload.length() > self.limits.max_message_bytes {
    raise WsError(
      kind=TooLarge(limit=self.limits.max_message_bytes),
      detail="outgoing wire message limit",
    )
  }
  self.emit(opcode, payload, rsv1~)
}

///|
async fn ConnSession::fail(
  self : ConnSession,
  error : WsError,
  code : CloseCode,
) -> Unit noraise {
  defer self.drop()
  self.failure = Some(error)
  self.closing = self.closing.request()
  self.control(Close, { code, reason: "", }.encode() catch { _ => b"" }) catch {
    _ => ()
  }
}

///|
async fn ConnSession::write_pong(self : ConnSession) -> Unit raise WsError {
  // Choose the latest Ping only after the lock is available, so a blocked
  // sender never causes a growing queue of Pong tasks or payloads.
  if self.pending_pong is None || !self.closing.data_allowed() {
    return
  }
  let ticket = self.lock.enqueue()
  defer self.lock.release(ticket)
  self.pong_progress = if ticket.granted { Starting } else { Queued }
  self.notify()
  let mut failure : WsError? = None
  let completed = self.timer.within(self.limits.send_timeout_ms, () => {
    ticket.signal.wait()
    if self.closing.data_allowed() && self.pending_pong is Some(payload) {
      self.pending_pong = None
      self.pong_progress = Writing
      self.notify()
      self.write_frame(Pong, payload) catch {
        error => failure = Some(error)
      }
      self.pong_progress = Settling
      self.notify()
    }
  })
  if !completed {
    self.abort()
    raise WsError(
      kind=Timeout(ms=self.limits.send_timeout_ms),
      detail="Pong send deadline",
    )
  }
  if failure is Some(error) {
    raise error
  }
}

///|
/// Shield the caller, not the Timer's child. Its deadline can still cancel a
/// write. The independent monitor also closes Conn at expiry, waking a write
/// whose own cancellation cleanup needs the transport to be closed first.
async fn ConnSession::control(
  self : ConnSession,
  opcode : @frame.Opcode,
  payload : Bytes,
) -> Unit raise WsError {
  let mut failure : WsError? = None
  self.coordination.protect(work=() => {
    self.coordination.supervise(
      primary=() => {
        try {
          if opcode is Pong {
            self.write_pong()
          } else {
            self.emit(opcode, payload)
          }
        } catch {
          error => if failure is None { failure = Some(error) }
        }
      },
      monitor=() => {
        self.clock.sleep(self.limits.send_timeout_ms.max(0))
        let error = WsError(
          kind=Timeout(ms=self.limits.send_timeout_ms),
          detail="control reply deadline",
        )
        if failure is None {
          failure = Some(error)
        }
        self.failure = failure
        self.abort()
      },
    )
  }) catch {
    cause =>
      raise WsError(kind=Transport(cause), detail="control reply coordination")
  }
  if failure is Some(error) {
    raise error
  }
}

///|
async fn ConnSession::flush_pong(self : ConnSession) -> Unit raise WsError {
  if self.pending_pong is Some(_) && self.closing.data_allowed() {
    self.pong_progress = Starting
    defer {
      self.pong_progress = Idle
      self.notify()
    }
    self.control(Pong, b"")
  }
}

///|
/// Give the independent writer a turn for an uncongested Ping. Never wait
/// for a queued or blocked write: it may depend on this parser reading the
/// peer's bytes. Once wire I/O has finished, join its bookkeeping before the
/// next Ping, so a free writer answers every Ping rather than coalescing a
/// whole batch just because its Timer/Coordination children have not unwound.
async fn ConnSession::offer_pong(
  self : ConnSession,
  payload : Bytes,
) -> Unit noraise {
  let busy = self.pong_progress is (Queued | Writing) ||
    !self.lock.queue.is_empty()
  self.pending_pong = Some(payload)
  self.notify()
  if busy {
    return
  }
  while self.closing.data_allowed() {
    let changed = self.changed
    match self.pong_progress {
      Queued => return
      Writing => {
        self.read_during_pong()
        return
      }
      Idle if self.pending_pong is None || !self.lock.queue.is_empty() => return
      Idle | Starting | Settling => changed.wait()
    }
  }
}

///|
/// Race a bounded read against the independent Pong finishing. A free
/// socket writer may await its I/O completion even when it is writable: do
/// not parse the rest of the current Ping batch before that completion.
/// If input is available, read it and resume parsing immediately, so blocked
/// peers drain each other's pipes and further Pings coalesce to the latest.
/// After a message is ready, finish may drain up to the same 64 KiB bound
/// past a deferred data head. Only one task ever owns the input direction.
async fn ConnSession::read_during_pong(
  self : ConnSession,
  finish~ : Bool = false,
) -> Unit noraise {
  if self.pong_read_error is Some(_) ||
    (!finish && !self.pong_read_ahead.is_empty()) {
    return
  }
  let ahead = Buffer()
  ahead.write_bytes(self.pong_read_ahead)
  self.pong_read_ahead = b""
  defer {
    self.pong_read_ahead = if self.closing.phase is Closed {
      b""
    } else {
      ahead.to_bytes()
    }
  }
  let completed = @mttp_core.TransportError(
    kind=Closed,
    phase=Body,
    detail="Pong completed",
  )
  self.coordination.supervise(
    primary=() => {
      for ;; {
        if ahead.length() >= 65536 {
          return
        }
        match self.conn.read(max_len=65536 - ahead.length()) {
          Some(bytes) => {
            ahead.write_bytes(bytes)
            self.life = self.life.received(self.clock.now_unix_ms())
            self.notify()
          }
          None => {
            // EOF is permanent: there is no input to unblock either writer.
            // Let an already started control finish before parsing buffered data.
            while (
                    self.pending_pong is Some(_) ||
                    !(self.pong_progress is Idle)
                  ) &&
                  self.closing.data_allowed() {
              self.changed.wait()
            }
            return
          }
        }
        if !finish {
          return
        }
      }
    },
    monitor=() => {
      while (self.pending_pong is Some(_) || !(self.pong_progress is Idle)) &&
            self.closing.data_allowed() {
        self.changed.wait()
      }
      raise completed
    },
  ) catch {
    cause =>
      if !physical_equal(cause, completed) {
        // This read followed all parser and read-ahead bytes. Deliver those
        // messages before exposing its terminal error through read_input.
        self.pong_read_error = Some(cause)
      }
  }
}

///|
async fn ConnSession::read_input(
  self : ConnSession,
) -> Bytes? raise @mttp_core.TransportError {
  if !self.pong_read_ahead.is_empty() {
    let bytes = self.pong_read_ahead
    self.pong_read_ahead = b""
    return Some(bytes)
  }
  if self.pong_read_error is Some(cause) {
    raise cause
  }
  self.conn.read(max_len=65536)
}

///|
async fn ConnSession::watch(self : ConnSession) -> Unit noraise {
  while self.closing.data_allowed() {
    self.flush_pong() catch {
      error => {
        self.failure = Some(error)
        self.abort()
      }
    }
    if !self.closing.data_allowed() {
      return
    }
    // A Ping may have arrived while the previous Pong was blocked. Its
    // notification preceded this continuation, so inspect state before waiting.
    if self.pending_pong is Some(_) {
      continue
    }
    let (life, ping) = self.life.tick(
      self.clock.now_unix_ms(),
      self.limits.ping_interval_ms,
      self.limits.pong_timeout_ms,
    )
    self.life = life
    if life is Zombie {
      self.failure = Some(
        WsError(
          kind=Timeout(ms=self.limits.pong_timeout_ms.unwrap_or(0)),
          detail="WebSocket zombie",
        ),
      )
      self.abort()
      return
    }
    if ping {
      self.control(Ping, b"") catch {
        error => {
          self.failure = Some(error)
          self.abort()
        }
      }
      self.life = self.life.sent(self.clock.now_unix_ms())
      continue
    }
    let changed = self.changed
    let delay = match
      (self.life, self.limits.ping_interval_ms, self.limits.pong_timeout_ms) {
      (Alive(last), Some(i), Some(a)) if i > 0 && a > 0 =>
        Some(
          (last + i.to_int64() - self.clock.now_unix_ms())
          .max(1L)
          .min(2147483647L)
          .to_int(),
        )
      (Waiting(last), _, Some(a)) if a > 0 =>
        Some(
          (last + a.to_int64() - self.clock.now_unix_ms())
          .max(1L)
          .min(2147483647L)
          .to_int(),
        )
      _ => None
    }
    match delay {
      Some(ms) => ignore(self.timer.within(ms, () => changed.wait()))
      None => changed.wait()
    }
  }
}
