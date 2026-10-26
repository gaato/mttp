///|
/// Serializes name/value pairs, in order, as an
/// `application/x-www-form-urlencoded` body with the WHATWG URL Standard's
/// urlencoded serializer, as browsers and `URLSearchParams` do: a space
/// becomes `+`, and every UTF-8 byte other than an ASCII alphanumeric or one
/// of `*-._` is percent-encoded in uppercase hex. This differs from
/// `percent_encode`, which keeps `~`, encodes `*` and writes a space as
/// `%20`. A lone surrogate is encoded as U+FFFD.
///
/// ```mbt check
/// test {
///   assert_eq(
///     @model.form_urlencode([("q", "a b&c"), ("lang", "日本")]),
///     "q=a+b%26c&lang=%E6%97%A5%E6%9C%AC",
///   )
/// }
/// ```
pub fn form_urlencode(pairs : ArrayView[(String, String)]) -> String {
  @form.encode(pairs)
}

///|
/// Encodes `pairs` with `form_urlencode` as the body and supplies
/// `application/x-www-form-urlencoded` only if content-type is absent.
pub fn Request::body_form(
  self : Request,
  pairs : ArrayView[(String, String)],
) -> Request {
  self.body_bytes(
    encode_utf8(form_urlencode(pairs)),
    content_type=self.headers
      .get("content-type")
      .unwrap_or("application/x-www-form-urlencoded"),
  )
}
