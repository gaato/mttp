///|
/// Each TLS layer has its own controllers, independent of the inner Conn's
/// buffering. This works equally over TCP and a CONNECT tunnel.
priv struct ConnIo {
  inner : &@rt.Conn
  reader : @io.BinaryReaderController
  writer : @io.BinaryWriterController
  /// How many writes the TLS layer has started on `inner` that may have
  /// sent bytes. A write counts from the moment it starts, so one that
  /// fails or is cancelled midway counts; one that raises `Closed` stops
  /// counting there, as `Closed` promises it sent nothing. A refusal never
  /// offsets a write that went through: `Closed` means `inner` is closed,
  /// so every later write on it is refused too.
  mut sends : Int64
}

///|
fn ConnIo::new(inner : &@rt.Conn) -> ConnIo {
  {
    inner,
    reader: @io.BinaryReaderController(),
    writer: @io.BinaryWriterController(),
    sends: 0L,
  }
}

///|
impl @io.BinaryReaderImpl for ConnIo with fn get_controller(self) {
  self.reader
}

///|
impl @io.BinaryWriterImpl for ConnIo with fn get_controller(self) {
  self.writer
}

///|
impl @io.BinaryReaderImpl for ConnIo with fn raw_read_impl(
  self,
  out,
  offset~,
  max_len~,
) {
  match self.inner.read(max_len~) {
    None => 0
    Some(bytes) => {
      for i in 0..<bytes.length() {
        out[offset + i] = bytes[i]
      }
      bytes.length()
    }
  }
}

///|
impl @io.BinaryWriterImpl for ConnIo with fn raw_write_impl(
  self,
  bytes,
  offset~,
  len~,
) {
  self.sends += 1L
  self.inner.write(bytes[offset:offset + len].to_owned()) catch {
    @mttp_core.TransportError(kind=Closed, ..) as error => {
      self.sends -= 1L
      raise error
    }
    error => raise error
  }
  len
}

///|
impl @io.BinaryReader for ConnIo

///|
impl @io.BinaryWriter for ConnIo
