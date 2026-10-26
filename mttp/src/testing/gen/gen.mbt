///|
/// Visits every two-chunk split, including empty prefix and suffix, without
/// retaining all partitions. The caller determines the input size.
pub fn each_split(
  bytes : Bytes,
  visit : (Bytes, Bytes) -> Unit raise?,
) -> Unit raise? {
  for split in 0..<=bytes.length() {
    visit(bytes[:split].to_owned(), bytes[split:].to_owned())
  }
}

///|
/// Chunks a value byte by byte, deliberately splitting multibyte UTF-8.
pub fn byte_chunks(bytes : Bytes) -> Array[Bytes] {
  Array::makei(bytes.length(), i => bytes[i:i + 1].to_owned())
}

///|
/// Generates nonempty partitions whose concatenation is exactly `bytes`.
/// Seeds belong to the caller's quickcheck runner; no global RNG is read.
pub fn chunks(bytes : Bytes) -> @qc.Generator[Array[Bytes]] {
  if bytes.is_empty() {
    return @qc.pure([])
  }
  @qc.int_range(1, bytes.length())
  .array_with_size(bytes.length())
  .map(widths => {
    let out = []
    let mut at = 0
    for width in widths {
      if at == bytes.length() {
        break
      }
      let end = at + width.min(bytes.length() - at)
      out.push(bytes[at:end].to_owned())
      at = end
    }
    out
  })
}

///|
/// Generates text covering ASCII, supplementary characters, combining marks
/// and unpaired UTF-16 surrogates. Size is capped to keep fuzz cases small.
pub fn text() -> @qc.Generator[String] {
  let high = String::from_array([(0xD800).unsafe_to_char()])
  let low = String::from_array([(0xDC00).unsafe_to_char()])
  @qc.sized(size => {
    @qc.elements(["a", " ", "é", "日本", "🙂", "e\u0301", high, low])
    .array_with_size(size.max(0).min(128))
    .map(parts => parts.join(""))
  })
}

///|
/// Generates ordered duplicate headers with mixed-case names, suitable for
/// checking lookup, replacement and persistence rather than wire validation.
pub fn headers() -> @qc.Generator[@model.Headers] {
  @qc.sized(size => {
    @qc.elements(["X-Test", "x-test", "Accept", "Set-Cookie"])
    .zip(text().resize(4))
    .array_with_size(size.max(0).min(32))
    .map(pairs => @model.Headers::of(pairs))
  })
}

///|
/// Generates raw URLs containing forbidden controls or space. These must be
/// rejected before a normalizing parser can percent-encode them.
pub fn invalid_url() -> @qc.Generator[String] {
  @qc.elements([0, 9, 10, 13, 31, 32, 127]).map(code => {
    "https://example.test/a" + code.unsafe_to_char().to_string() + "b"
  })
}
