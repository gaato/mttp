///|
/// Whether `error`, raised by a read of a TLS session, says that the peer
/// closed the connection beneath without close_notify. core/async's TLS
/// client raises `@io.UnexpectedEof` then (it requires close_notify by
/// default), and `@io.BinaryReader::read_into` wraps what the session
/// raises in `@io.ReaderError::TransportError`.
fn incomplete_close(error : Error) -> Bool {
  error
  is (@io.UnexpectedEof
  | @io.ReaderError::TransportError(@io.UnexpectedEof, ..))
}
