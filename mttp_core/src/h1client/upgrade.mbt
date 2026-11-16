///|
priv struct Upgrade {
  conn : UpgradedConn
  mut pending : Bytes?
}

///|
priv struct UpgradedConn {
  wire : Wire
  slots : Slots
  key : String
  mut closed : Bool
}

///|
impl @rt.Upgraded for Upgrade with fn take_conn(self) {
  guard self.pending is Some(bytes) else { return None }
  self.pending = None
  Some((self.conn, bytes))
}

///|
impl @rt.Conn for UpgradedConn with fn read(self, max_len~) {
  self.wire.conn.read(max_len~)
}

///|
impl @rt.Conn for UpgradedConn with fn write(self, bytes) {
  self.wire.conn.write(bytes)
}

///|
impl @rt.Conn for UpgradedConn with fn close(self) {
  if !self.closed {
    self.closed = true
    self.wire.close()
    self.slots.release(self.key)
  }
}
