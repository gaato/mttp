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
  /// The last error `inner` raised to the TLS layer, which `SocketConn`
  /// reports in place of an error the session wraps. MoonBit 0.10.20's
  /// core/async passes such an error up through `Tls` unchanged; later
  /// toolchains wrap it in `@io.ReaderError` or `@io.WriterError`, which
  /// source that builds on both cannot match. The session keeps a read's
  /// error and raises it again from later operations, so once `inner` has
  /// failed, the session's failures stem from the last error here.
  mut failure : @mttp_core.TransportError?
}

///|
fn ConnIo::new(inner : &@rt.Conn) -> ConnIo {
  {
    inner,
    reader: @io.BinaryReaderController(),
    writer: @io.BinaryWriterController(),
    sends: 0L,
    failure: None,
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
  let read = self.inner.read(max_len~) catch {
    @mttp_core.TransportError(..) as error => {
      self.failure = Some(error)
      raise error
    }
  }
  match read {
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
      self.failure = Some(error)
      raise error
    }
    error => {
      self.failure = Some(error)
      raise error
    }
  }
  len
}

///|
impl @io.BinaryReader for ConnIo

///|
impl @io.BinaryWriter for ConnIo
