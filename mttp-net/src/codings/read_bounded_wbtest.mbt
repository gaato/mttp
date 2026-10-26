///|
/// Chunks from `read` until it returns `None`. The chunk that would take the
/// total past `max_bytes` raises `Protocol` without reading further.
async fn read_bounded(read : async () -> Bytes?, max_bytes : Int32) -> Bytes {
  let body = Buffer()
  while read() is Some(chunk) {
    if chunk.length() > max_bytes - body.length() {
      raise @model.TransportError(
        kind=Protocol,
        phase=Body,
        detail="response body larger than \{max_bytes} bytes",
      )
    }
    body.write_bytes(chunk)
  }
  body.to_bytes()
}
