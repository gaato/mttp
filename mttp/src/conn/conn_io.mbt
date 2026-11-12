///|
/// Each TLS layer has its own controllers, independent of the inner Conn's
/// buffering. This works equally over TCP and a CONNECT tunnel.
priv struct ConnIo {
  inner : &@rt.Conn
  reader : @io.BinaryReaderController
  writer : @io.BinaryWriterController
}

///|
fn ConnIo::new(inner : &@rt.Conn) -> ConnIo {
  {
    inner,
    reader: @io.BinaryReaderController(),
    writer: @io.BinaryWriterController(),
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
  self.inner.write(bytes[offset:offset + len].to_owned())
  len
}

///|
impl @io.BinaryReader for ConnIo

///|
impl @io.BinaryWriter for ConnIo
