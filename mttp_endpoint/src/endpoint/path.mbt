///|
// Literal text is decoded route data, not an already-escaped URL fragment.
// Share its wire encoding between client requests and documented templates.
fn encoded_literal_segment(text : String) -> String {
  "/" + @http.percent_encode(text)
}

///|
/// Renders an endpoint template with wire-encoded literal segments, preserving
/// capture placeholders. Rest captures project to ordinary named placeholders;
/// their slash-separated serialization is described separately in metadata.
///
/// ```mbt check
/// test {
///   assert_eq(
///     @endpoint.encoded_path_template("/files/a%2Fb/{id}"),
///     "/files/a%252Fb/{id}",
///   )
/// }
/// ```
pub fn encoded_path_template(template : String) -> String {
  let builder = StringBuilder()
  for segment in parse_template(template) {
    match segment {
      Lit(text) => builder.write_string(encoded_literal_segment(text))
      Cap(name) | Rest(name) => builder.write_string("/{" + name + "}")
    }
  }
  let result = builder.to_string()
  if result.is_empty() {
    "/"
  } else {
    result
  }
}
