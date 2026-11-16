// RFC 1928 sections 3-6 and RFC 1929 section 2. The state machine consumes
// one bounded reply at a time; it never keeps application or tunnel bytes.

///|
fn socks_credentials(info : String) -> Bytes? {
  guard info.find(":") is Some(colon) else { return None }
  let user = @mttp_core.percent_decode(info[:colon].to_owned()) catch {
    _ => return None
  }
  let password = @mttp_core.percent_decode(info[colon + 1:].to_owned()) catch {
    _ => return None
  }
  let user = @mttp_core.encode_utf8(user)
  let password = @mttp_core.encode_utf8(password)
  guard user.length() >= 1 &&
    user.length() <= 255 &&
    password.length() >= 1 &&
    password.length() <= 255 else {
    return None
  }
  let bytes = Buffer()
  bytes.write_byte(1)
  bytes.write_byte(user.length().to_byte())
  bytes.write_bytes(user)
  bytes.write_byte(password.length().to_byte())
  bytes.write_bytes(password)
  Some(bytes.to_bytes())
}

///|
priv struct SocksHandshake {
  auth : Bytes?
  request : Bytes
  /// 0 method, 1 credentials, 2 CONNECT reply, 3 tunnel open.
  mut stage : Int32
  mut reply : Bytes
  mut need : Int32
  mut output : Bytes
}

///|
fn socks_error(
  kind : @mttp_core.Kind,
  detail : String,
) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind~, phase=Dial, detail="SOCKS5: " + detail)
}

///|
fn SocksHandshake::new(
  host : String,
  port : Int32,
  auth : Bytes?,
) -> SocksHandshake raise @mttp_core.TransportError {
  let request = Buffer()
  request.write_bytes(b"\x05\x01\x00")
  // Literals need no resolver port: RFC 1928 carries their network bytes.
  if ipv4_bytes(host) is Some(address) {
    request.write_byte(1)
    for byte in address {
      request.write_byte(byte.to_byte())
    }
  } else if ipv6_bytes(host) is Some(address) {
    request.write_byte(4)
    for byte in address {
      request.write_byte(byte.to_byte())
    }
  } else {
    let host = @mttp_core.encode_utf8(host)
    guard host.length() >= 1 && host.length() <= 255 else {
      raise socks_error(Invalid, "target name must contain 1..255 UTF-8 bytes")
    }
    request.write_byte(3)
    request.write_byte(host.length().to_byte())
    request.write_bytes(host)
  }
  request.write_byte((port >> 8).to_byte())
  request.write_byte((port & 255).to_byte())
  {
    auth,
    request: request.to_bytes(),
    stage: 0,
    reply: b"",
    need: 2,
    // Offering only password auth when credentials exist prevents downgrade.
    output: if auth is Some(_) {
      b"\x05\x01\x02"
    } else {
      b"\x05\x01\x00"
    },
  }
}

///|
fn SocksHandshake::take_output(self : SocksHandshake) -> Bytes {
  let output = self.output
  self.output = b""
  output
}

///|
/// Feeds at most `need - reply.length()` bytes. Max retained reply: 262
/// bytes (VER REP RSV ATYP LEN + 255-byte name + two port bytes).
fn SocksHandshake::feed(
  self : SocksHandshake,
  bytes : BytesView,
) -> Unit raise @mttp_core.TransportError {
  guard self.stage != 3 && bytes.length() <= self.need - self.reply.length() else {
    raise socks_error(Protocol, "reply exceeds its bound")
  }
  self.reply = self.reply + bytes.to_owned()
  if self.reply.length() < self.need {
    return
  }
  let reply = self.reply
  if self.stage == 0 {
    guard reply[0] == 5 else {
      raise socks_error(Protocol, "invalid method version")
    }
    let expected : Byte = if self.auth is Some(_) { 2 } else { 0 }
    guard reply[1] == expected else {
      raise socks_error(Proxy(status=407), "authentication method refused")
    }
    self.stage = if self.auth is Some(_) { 1 } else { 2 }
    self.output = self.auth.unwrap_or(self.request)
    self.need = if self.stage == 1 { 2 } else { 4 }
  } else if self.stage == 1 {
    guard reply[0] == 1 else {
      raise socks_error(Protocol, "invalid authentication version")
    }
    guard reply[1] == 0 else {
      raise socks_error(Proxy(status=407), "username/password refused")
    }
    self.stage = 2
    self.output = self.request
    self.need = 4
  } else {
    guard reply[0] == 5 && reply[2] == 0 else {
      raise socks_error(Protocol, "invalid CONNECT version or reserved byte")
    }
    if reply[1] != 0 {
      raise socks_error(
        Proxy(status=reply[1].to_int()),
        "CONNECT refused (RFC 1928 reply code \{reply[1].to_int()})",
      )
    }
    if reply.length() == 4 {
      self.need = match reply[3] {
        1 => 10
        4 => 22
        3 => 5
        _ => raise socks_error(Protocol, "invalid reply address type")
      }
      return
    }
    if reply[3] == 3 && reply.length() == 5 {
      guard reply[4] != 0 else {
        raise socks_error(Protocol, "empty bound name")
      }
      self.need = 7 + reply[4].to_int()
      return
    }
    self.stage = 3
    self.need = 0
  }
  self.reply = b""
}

///|
async fn open_socks_tunnel(
  wire : Wire,
  target : Target,
  auth : Bytes?,
) -> Unit raise @mttp_core.TransportError {
  let state = SocksHandshake::new(target.host, target.port, auth)
  while state.stage != 3 {
    let output = state.take_output()
    if !output.is_empty() {
      wire.write(output)
    }
    match wire.read(state.need - state.reply.length()) {
      Data(bytes) => state.feed(bytes)
      End(..) => raise socks_error(Connect, "EOF during handshake")
    }
  }
}
