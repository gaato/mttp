///|
/// Transfer one stream reader, or slice caller-owned bytes without buffering
/// the whole representation again. Both wrappers use this ownership boundary.
fn body_source(
  body : @http.Body,
) -> (async () -> Bytes? raise @http.TransportError, () -> Unit) raise @http.TransportError {
  match body {
    Stream(stream) => {
      let reader = stream.take()
      (() => reader.read_some(), () => reader.close())
    }
    Empty | Bytes(_) => {
      let bytes = body.as_bytes().unwrap_or(b"")
      let offset = Ref(0)
      (
        () => {
          if offset.val == bytes.length() {
            return None
          }
          let end = offset.val + (bytes.length() - offset.val).min(65536)
          let chunk = bytes[offset.val:end].to_owned()
          offset.val = end
          Some(chunk)
        },
        () => (),
      )
    }
    @http.Body::.. =>
      raise @http.TransportError(
        kind=Invalid,
        phase=Body,
        detail="unsupported body representation",
      )
  }
}
