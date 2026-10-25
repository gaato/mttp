///|
/// The next chunk of a body: the next `read`, or with a `decoder`, the next
/// decoded slice, reading only as much as that slice needs.
/// The caller retains ownership of the upstream reader and closes it on exit.
pub async fn read_decoded(
  read : async () -> Bytes?,
  decoder : ContentDecoder?,
) -> Bytes? {
  guard decoder is Some(decoder) else { return read() }
  for ;; {
    match decoder.pull() {
      Slice(slice) => return Some(slice)
      Done => return None
      NeedInput =>
        match read() {
          Some(chunk) => decoder.feed(chunk)
          None => decoder.end()
        }
    }
  }
}
