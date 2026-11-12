///|
priv struct BridgeSource {
  mut offset : Int32
  bytes : Bytes
  written : Buffer
}

///|
impl @rt.Conn for BridgeSource with fn read(self, max_len~) {
  if self.offset == self.bytes.length() {
    return None
  }
  let end = self.offset +
    (self.bytes.length() - self.offset).min(max_len).min(2)
  let bytes = self.bytes[self.offset:end].to_owned()
  self.offset = end
  Some(bytes)
}

///|
impl @rt.Conn for BridgeSource with fn write(self, bytes) {
  self.written.write_bytes(bytes)
}

///|
impl @rt.Conn for BridgeSource with fn close(_) {
  ()
}

///|
async test "ConnIo owns independent controllers buffers read ahead and writes offset ranges" {
  let source = BridgeSource::{ offset: 0, bytes: b"abcdef", written: Buffer(), }
  let bridge = ConnIo::new(source)
  let other = ConnIo::new(source)
  assert_false(
    physical_equal(
      @io.BinaryReaderImpl::get_controller(bridge),
      @io.BinaryReaderImpl::get_controller(other),
    ),
  )
  // The writer controller is currently stateless; only the reader has mutable
  // buffering whose identity must differ between bridges.
  assert_eq(@io.BinaryReader::peek_exactly(bridge, 3).to_owned(), b"abc")
  assert_eq(@io.BinaryReader::read_exactly(bridge, 4), b"abcd")
  assert_eq(@io.BinaryReader::read_all(bridge), b"ef")
  assert_eq(@io.BinaryReader::read(bridge), None)
  assert_eq(
    @io.BinaryWriterImpl::raw_write_impl(bridge, b"_hello_", offset=1, len=5),
    5,
  )
  @io.BinaryWriter::write(bridge, b"!")
  assert_eq(source.written.to_bytes(), b"hello!")
}

///|
/// A connection whose writes fail with the next of `failures`, or go
/// through once those run out.
priv struct ScriptedWrites {
  failures : Array[@mttp_core.Kind]
}

///|
impl @rt.Conn for ScriptedWrites with fn read(_, max_len~) {
  ignore(max_len)
  None
}

///|
impl @rt.Conn for ScriptedWrites with fn write(self, _) {
  if self.failures.pop() is Some(kind) {
    raise @mttp_core.TransportError(kind~, phase=Unknown, detail="scripted")
  }
}

///|
impl @rt.Conn for ScriptedWrites with fn close(_) {
  ()
}

///|
async test "ConnIo counts the writes beneath that may have sent bytes" {
  // Popped from the end: Network, then Closed, then success.
  let bridge = ConnIo::new(ScriptedWrites::{ failures: [Closed, Network], })
  let sends = []
  for _ in 0..<3 {
    @io.BinaryWriter::write(bridge, b"x") catch {
      _ => ()
    }
    sends.push(bridge.sends)
  }
  // A write that failed with `Network` may have sent part; one refused with
  // `Closed` sent nothing; one that went through did.
  assert_eq(sends, [1L, 1L, 2L])
}
