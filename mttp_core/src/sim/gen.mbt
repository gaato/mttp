// Inputs for property tests. The quickcheck generators take their seed from
// the caller's runner and read no global random source, so a sample is the
// same on every target; the sized ones clamp the requested size so a large
// size cannot make a test allocate without limit.

///|
/// The most pieces `gen_text` joins.
let max_text_pieces : Int32 = 128

///|
/// The most pairs `gen_headers` generates.
let max_header_pairs : Int32 = 32

///|
/// Calls `visit` with every split of `bytes` into two pieces, including an
/// empty first or second piece, without keeping the splits.
pub fn each_split(
  bytes : Bytes,
  visit : (Bytes, Bytes) -> Unit raise?,
) -> Unit raise? {
  for split in 0..<=bytes.length() {
    visit(bytes[:split].to_owned(), bytes[split:].to_owned())
  }
}

///|
/// `bytes` one byte per chunk, splitting every multibyte UTF-8 sequence.
pub fn byte_chunks(bytes : Bytes) -> Array[Bytes] {
  Array::makei(bytes.length(), i => bytes[i:i + 1].to_owned())
}

///|
/// Nonempty chunks that concatenate to exactly `bytes`.
///
/// ```mbt check
/// test {
///   for chunks in @sim.gen_chunks(b"chunked").samples(count=20, seed=7) {
///     assert_true(chunks.all(chunk => !chunk.is_empty()))
///     let out = Buffer()
///     chunks.each(chunk => out.write_bytes(chunk))
///     assert_eq(out.to_bytes(), b"chunked")
///   }
/// }
/// ```
pub fn gen_chunks(bytes : Bytes) -> @qc.Generator[Array[Bytes]] {
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
/// Text of ASCII, a space, accented and CJK characters, an emoji, a
/// combining mark and unpaired UTF-16 surrogates: at most 128 pieces, so at
/// most 256 UTF-16 code units, whatever the requested size.
pub fn gen_text() -> @qc.Generator[String] {
  let high = String::from_array([(0xD800).unsafe_to_char()])
  let low = String::from_array([(0xDC00).unsafe_to_char()])
  @qc.sized(size => {
    @qc.elements(["a", " ", "é", "日本", "🙂", "é", high, low])
    .array_with_size(size.max(0).min(max_text_pieces))
    .map(parts => parts.join(""))
  })
}

///|
/// Headers with duplicate and mixed-case names in order, at most 32 pairs,
/// for lookup and replacement tests. The values are `gen_text`, so they are
/// not valid on the wire.
pub fn gen_headers() -> @qc.Generator[@mttp_core.Headers] {
  @qc.sized(size => {
    @qc.elements(["X-Test", "x-test", "Accept", "Set-Cookie"])
    .zip(gen_text().resize(4))
    .array_with_size(size.max(0).min(max_header_pairs))
    .map(pairs => @mttp_core.Headers::of(pairs))
  })
}

///|
/// URLs containing a control character or a space, which a sender must
/// refuse before a normalizing parser could percent-encode them.
pub fn gen_invalid_url() -> @qc.Generator[String] {
  @qc.elements([0, 9, 10, 13, 31, 32, 127]).map(code => {
    "https://example.test/a" + code.unsafe_to_char().to_string() + "b"
  })
}

///|
/// Checks that `parse` gives the same value for `input` in one chunk, split
/// in two at every offset (empty pieces included) and one byte per chunk.
/// To compare failures as well, return them as part of the value. Raises at
/// the first split that differs.
///
/// ```mbt check
/// test {
///   @sim.check_splits(b"a\r\nb", chunks => {
///     let out = Buffer()
///     chunks.each(chunk => out.write_bytes(chunk))
///     out.to_bytes()
///   })
/// }
/// ```
pub fn[T : Eq + @debug.Debug] check_splits(
  input : Bytes,
  parse : (Array[Bytes]) -> T raise,
) -> Unit raise {
  let expected = parse([input])
  for cut in 0..<=input.length() {
    assert_eq(
      parse([input[:cut].to_owned(), input[cut:].to_owned()]),
      expected,
      msg="parser differs at split \{cut}",
    )
  }
  assert_eq(
    parse(byte_chunks(input)),
    expected,
    msg="parser differs for single-byte chunks",
  )
}
