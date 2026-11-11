///|
/// UTF-8 HTML pages, as `text/html; charset=utf-8`. The value is the page
/// itself: render it with any template engine and pass the string. Decoding
/// is strict UTF-8; encoding replaces lone surrogates.
pub let html_body : BodyCodec[String] = {
  ..text_body,
  media_type_: "text/html; charset=utf-8",
}
