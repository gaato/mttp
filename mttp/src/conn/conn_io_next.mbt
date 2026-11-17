///|
impl @io.BinaryReaderImpl for ConnIo with fn name(_) {
  "@conn.ConnIo"
}

///|
impl @io.BinaryWriterImpl for ConnIo with fn name(_) {
  "@conn.ConnIo"
}

///|
/// ConnIo keeps no bytes of its own: each write goes to `inner` whole.
impl @io.BinaryWriterImpl for ConnIo with fn flush_partial_data(_) {

}
