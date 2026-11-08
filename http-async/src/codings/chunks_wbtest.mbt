///|
fn random_chunks(rand : @random.Rand, body : Bytes) -> Array[Bytes] {
  let chunks = []
  let mut start = 0
  while start < body.length() {
    let end = start + rand.int(limit=body.length() - start + 1)
    chunks.push(body[start:end].to_owned())
    start = end
  }
  if rand.int(limit=4) == 0 {
    chunks.push(b"")
  }
  chunks
}
