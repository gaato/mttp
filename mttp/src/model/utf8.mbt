///|
/// Encodes `text` as UTF-8, writing each lone surrogate as U+FFFD, as the
/// WHATWG Encoding Standard's UTF-8 encoder and `TextEncoder` do.
/// `@utf8.encode` aborts the process on a lone surrogate instead, so it is
/// unsafe for strings that came from outside.
///
/// ```mbt check
/// test {
///   let lone = String::from_array([(0xD800).unsafe_to_char()])
///   assert_eq(@model.encode_utf8("é" + lone), b"\xC3\xA9\xEF\xBF\xBD")
/// }
/// ```
pub fn encode_utf8(text : String) -> Bytes {
  @text.encode_utf8(text)
}
