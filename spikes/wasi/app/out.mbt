///|
/// Lines go to one stdout stream opened by `main`, so that output appears as
/// the spike runs instead of at its end.
let out : Ref[@async-core.Sink[Byte]?] = Ref(None)

///|
pub async fn say(line : String) -> Unit {
  guard out.val is Some(sink) else { return }
  let bytes = @utf8.encode(line + "\n")
  ignore(sink.write_all_bytes(bytes))
}
