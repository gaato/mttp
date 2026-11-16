///|
/// Sets PUT and appends a path template.
pub fn[S, I, E, O, M] Endpoint::put(
  self : Endpoint[S, I, E, O, M],
  template : String,
) -> Endpoint[S, I, E, O, M] {
  self.with_method(Put, template)
}

///|
/// Sets PATCH and appends a path template.
pub fn[S, I, E, O, M] Endpoint::patch(
  self : Endpoint[S, I, E, O, M],
  template : String,
) -> Endpoint[S, I, E, O, M] {
  self.with_method(Patch, template)
}

///|
/// Sets HEAD and appends a path template.
pub fn[S, I, E, O, M] Endpoint::head(
  self : Endpoint[S, I, E, O, M],
  template : String,
) -> Endpoint[S, I, E, O, M] {
  self.with_method(Head, template)
}

///|
/// Sets OPTIONS and appends a path template.
pub fn[S, I, E, O, M] Endpoint::options(
  self : Endpoint[S, I, E, O, M],
  template : String,
) -> Endpoint[S, I, E, O, M] {
  self.with_method(Options, template)
}

///|
/// Attaches a longer operation description.
pub fn[S, I, E, O, M] Endpoint::description(
  self : Endpoint[S, I, E, O, M],
  description : String,
) -> Endpoint[S, I, E, O, M] {
  { ..self, info: { ..self.info, description: Some(description), }, }
}

///|
/// Marks an operation deprecated in generated documentation.
pub fn[S, I, E, O, M] Endpoint::deprecated(
  self : Endpoint[S, I, E, O, M],
  deprecated~ : Bool = true,
) -> Endpoint[S, I, E, O, M] {
  { ..self, info: { ..self.info, deprecated, }, }
}

///|
/// A UTF-8 text response.
pub fn text_out(status~ : Int32 = 200) -> Out[String, @client.Buffered] {
  json_out(@schema.text_body, status~)
}

///|
/// A rendered HTML page (`text/html; charset=utf-8`). Render the page in the
/// handler with any template engine and return the string; a client reads it
/// back as the same string. For an error page, pass it to `errors` with its
/// status, as in `html_out(status=404)`; for several statuses, use
/// `html_variant` in `one_of`.
pub fn html_out(status~ : Int32 = 200) -> Out[String, @client.Buffered] {
  json_out(@schema.html_body, status~)
}

///|
/// An HTML page as one variant of `one_of`, for an endpoint that answers
/// with a page or with something else, such as a page for htmx and a 303
/// redirect without it, or an error page per status.
pub fn html_variant(status : Int32, description? : String) -> Variant[String] {
  json_variant(status, @schema.html_body, description?)
}

///|
/// An opaque application/octet-stream response.
pub fn bytes_out(status~ : Int32 = 200) -> Out[Bytes, @client.Buffered] {
  json_out(@schema.raw_bytes, status~)
}

///|
/// Adds a named example to every request media representation. Names must be
/// unique per request; definition checking refuses examples without a body.
pub fn[S, I, E, O, M] Endpoint::request_example(
  self : Endpoint[S, I, E, O, M],
  name : String,
  value : Json,
  summary? : String,
) -> Endpoint[S, I, E, O, M] {
  {
    ..self,
    request_examples: [..self.request_examples, (name, value, summary)],
  }
}

///|
/// Adds a named example to every media representation at a declared response
/// status. Names must be unique within that status, including declared errors.
pub fn[S, I, E, O, M] Endpoint::response_example(
  self : Endpoint[S, I, E, O, M],
  status : Int32,
  name : String,
  value : Json,
  summary? : String,
) -> Endpoint[S, I, E, O, M] {
  {
    ..self,
    response_examples: [
      ..self.response_examples,
      (status, name, value, summary),
    ],
  }
}
