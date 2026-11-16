///|
/// A rendezvous direction: one chunk (at most 64 KiB) is retained while
/// its writer waits for consumption. This supplies backpressure without I/O.
priv struct UpgradePipe {
  mut bytes : Bytes
  mut closed : Bool
  mut changed : &@rt.Signal
  coordination : &@rt.Coordination
}

///|
fn UpgradePipe::new(coordination : &@rt.Coordination) -> UpgradePipe {
  { bytes: b"", closed: false, changed: coordination.signal(), coordination, }
}

///|
fn UpgradePipe::notify(self : UpgradePipe) -> Unit {
  let changed = self.changed
  self.changed = self.coordination.signal()
  changed.notify()
}

///|
priv struct UpgradeConn {
  input : UpgradePipe
  output : UpgradePipe
}

///|
impl @rt.Conn for UpgradeConn with fn read(self, max_len~) {
  if max_len <= 0 {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Body,
      detail="nonpositive read size",
    )
  }
  while self.input.bytes.is_empty() && !self.input.closed {
    self.input.changed.wait()
  }
  if self.input.closed {
    return None
  }
  let n = max_len.min(self.input.bytes.length())
  let bytes = self.input.bytes[:n].to_owned()
  self.input.bytes = self.input.bytes[n:].to_owned()
  self.input.notify()
  Some(bytes)
}

///|
impl @rt.Conn for UpgradeConn with fn write(self, bytes) {
  // A cancelled partial write cannot be resumed as a fresh frame.
  let mut complete = false
  defer (if !complete { @rt.Conn::close(self) })
  for offset = 0; offset < bytes.length(); {
    while !self.output.bytes.is_empty() && !self.output.closed {
      self.output.changed.wait()
    }
    if self.output.closed {
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Write,
        detail="closed in-process connection",
      )
    }
    let end = offset + (bytes.length() - offset).min(65536)
    self.output.bytes = bytes[offset:end].to_owned()
    self.output.notify()
    continue end
  }
  while !self.output.bytes.is_empty() && !self.output.closed {
    self.output.changed.wait()
  }
  if self.output.closed {
    raise @mttp_core.TransportError(
      kind=Network,
      phase=Write,
      detail="closed in-process connection",
    )
  }
  complete = true
}

///|
impl @rt.Conn for UpgradeConn with fn close(self) {
  self.input.closed = true
  self.input.bytes = b""
  self.input.notify()
  self.output.closed = true
  self.output.bytes = b""
  self.output.notify()
}

///|
fn Router::upgrade_response(
  self : Router,
  request : @mttp_core.Request,
  response : @mttp_core.Response,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  guard request.headers.get_all("upgrade").iter().any(v => !v.trim().is_empty()) &&
    request.headers
    .get_all("connection")
    .iter()
    .any(v => v.split(",").any(t => t.trim().to_owned().to_lower() == "upgrade")) &&
    response.attributes.get(@rt.upgrade) is Some(upgrade) else {
    raise @mttp_core.TransportError(
      kind=Protocol,
      phase=Head,
      detail="101 without an upgrade",
    )
  }
  guard self.clock is Some(clock) &&
    self.timer is Some(timer) &&
    self.coordination is Some(coordination) &&
    self.background is Some(background) else {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Head,
      detail="in-process upgrade requires clock, timer, coordination and background",
    )
  }
  let left = UpgradePipe::new(coordination)
  let right = UpgradePipe::new(coordination)
  let client : &@rt.Conn = UpgradeConn::{ input: left, output: right, }
  let server : &@rt.Conn = UpgradeConn::{ input: right, output: left, }
  let session = @ws.session_over_conn(
    client,
    role=Client,
    pending=b"",
    clock~,
    timer~,
    coordination~,
    // The mask stays inside this byte pair, never on an external transport.
    entropy=n => {
      Some(
        Bytes::makei(n, _ => (@rt.default_random() * 256.0).to_int().to_byte()),
      )
    },
    subprotocol?=response.headers.get("sec-websocket-protocol"),
  )
  background(() => {
    defer server.close()
    upgrade(server, b"", () => self.closed)
  })
  response.close()
  {
    ..response,
    body: Empty,
    attributes: @mttp_core.Attributes::empty().put(@ws.ws_session, session),
  }
}
