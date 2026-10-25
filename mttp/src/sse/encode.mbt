///|
/// Encodes one event as UTF-8, ending with a blank line. Data line endings
/// become LF; each line gets its own data field. Event names and IDs cannot
/// contain line breaks, IDs cannot contain NUL, and retries must be
/// nonnegative. Invalid fields raise Invalid rather than injecting fields.
pub fn encode(event : SseEvent) -> Bytes raise @model.TransportError {
  if event.event.contains("\r") || event.event.contains("\n") {
    raise @model.TransportError(
      kind=Invalid,
      phase=Write,
      detail="SSE event name contains a line break",
    )
  }
  if event.id is Some(id) &&
    (id.contains("\r") || id.contains("\n") || id.contains("\u0000")) {
    raise @model.TransportError(
      kind=Invalid,
      phase=Write,
      detail="invalid SSE id",
    )
  }
  if event.retry is Some(retry) && retry < 0 {
    raise @model.TransportError(
      kind=Invalid,
      phase=Write,
      detail="negative SSE retry",
    )
  }
  let out = StringBuilder()
  if !event.event.is_empty() {
    out.write_string("event: " + event.event + "\n")
  }
  if event.id is Some(id) {
    out.write_string("id: " + id + "\n")
  }
  if event.retry is Some(retry) {
    out.write_string("retry: \{retry}\n")
  }
  let data = event.data
    .replace_all(old="\r\n", new="\n")
    .replace_all(old="\r", new="\n")
  for line in data.split("\n") {
    out.write_string("data: " + line.to_owned() + "\n")
  }
  out.write_char('\n')
  @model.encode_utf8(out.to_string())
}
