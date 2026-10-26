///|
priv struct SocketConn {
  tcp : @socket.Tcp
  mut closed : Bool
}

///|
impl @connection.Conn for SocketConn with fn read(self, max_len~) {
  if self.closed {
    return None
  }
  self.tcp.read_some(max_len~) catch {
    error =>
      raise @model.TransportError(
        kind=Network,
        phase=Unknown,
        detail=error.to_string(),
      )
  }
}

///|
impl @connection.Conn for SocketConn with fn write(self, bytes) {
  if self.closed {
    raise @model.TransportError(
      kind=Network,
      phase=Unknown,
      detail="connection closed",
    )
  }
  self.tcp.write(bytes) catch {
    error =>
      raise @model.TransportError(
        kind=Network,
        phase=Unknown,
        detail=error.to_string(),
      )
  }
}

///|
impl @connection.Conn for SocketConn with fn close(self) {
  if !self.closed {
    self.closed = true
    self.tcp.close()
  }
}

///|
// Accepted sockets cross the runtime boundary only inside mttp-net.
pub fn from_tcp(tcp : @socket.Tcp) -> &@connection.Conn {
  SocketConn::{ tcp, closed: false, }
}
