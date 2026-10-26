///|
/// Compares authentication descriptions.
pub extend AuthScheme with Eq::{equal, not_equal}

///|
/// Formats authentication descriptions.
pub extend AuthScheme with @debug.Debug::{to_repr}

///|
/// Compares input locations.
pub extend Location with Eq::{equal, not_equal}

///|
/// Formats input locations.
pub extend Location with @debug.Debug::{to_repr}

///|
/// Compares route segments.
pub extend Seg with Eq::{equal, not_equal}

///|
/// Formats route segments.
pub extend Seg with @debug.Debug::{to_repr}

///|
/// Compares definition findings.
pub extend DefinitionProblem with Eq::{equal, not_equal}

///|
/// Formats definition findings.
pub extend DefinitionProblem with @debug.Debug::{to_repr}

///|
/// Formats a rejected definition.
pub extend DefinitionError with @debug.Debug::{to_repr}

///|
/// Formats the uninhabited declared-error type.
pub extend NoError with @debug.Debug::{to_repr}

///|
/// Describes one input read by a typed decoder.
pub fn Atom::new(
  location : Location,
  name : String,
  schema : @schema.Schema,
  required~ : Bool = true,
  description? : String,
  rest~ : Bool = false,
) -> Atom {
  { location, name, schema, required, description, rest, }
}

///|
/// Associates one input description with its decoding failure.
pub fn InputFailure::new(
  atom : Atom,
  failure : @schema.DecodeFailure,
) -> InputFailure {
  { atom, failure, }
}

///|
/// Creates operation metadata. Builder methods copy tags when extending them.
pub fn Info::new(
  operation_id? : String,
  summary? : String,
  description? : String,
  tags~ : Array[String] = [],
  deprecated~ : Bool = false,
) -> Info {
  { operation_id, summary, description, tags: tags.copy(), deprecated, }
}

///|
/// Creates a definition finding; fatal findings prevent interpreter creation.
pub fn DefinitionProblem::new(
  template : String,
  message : String,
  fatal~ : Bool = true,
) -> DefinitionProblem {
  { template, message, fatal, }
}

///|
/// Describes one response representation for definition checking and docs.
pub fn VariantDoc::new(
  status : Int32,
  media_type? : String,
  schema? : @schema.Schema,
  headers~ : Array[String] = [],
  description~ : String = "",
  header_schemas~ : Map[String, @schema.Schema] = {},
  dynamic_status~ : Bool = false,
  dynamic_media~ : Bool = false,
) -> VariantDoc {
  {
    status,
    media_type,
    schema,
    headers: headers.copy(),
    description,
    header_schemas: header_schemas.copy(),
    dynamic_status,
    dynamic_media,
  }
}

///|
/// Supplies head-only data to an input decoder. Query pairs and captures are
/// already decoded by the dispatcher; no body is read by this constructor.
pub fn Head::new(
  request : @model.Request,
  captures~ : Map[String, String] = {},
  query~ : Array[(String, String)] = [],
) -> Head {
  { request, captures: captures.copy(), query: query.copy(), }
}

///|
/// Completes an input using only the request head.
pub fn[T] Staged::ready(value : T) -> Staged[T] {
  ready(value)
}

///|
/// Defers an input's final decoding until the dispatcher supplies the body.
pub fn[T] Staged::after_body(
  finish : (BodyValue) -> T raise InputErrors,
) -> Staged[T] {
  { needs_body: true, finish, }
}

///|
/// Sets a header during client request encoding, replacing earlier values.
pub fn RequestSink::set_header(
  self : RequestSink,
  name : String,
  value : String,
) -> Unit {
  self.headers = self.headers.set(name, value)
}

///|
/// Adds an ordered query pair during client request encoding.
pub fn RequestSink::add_query(
  self : RequestSink,
  name : String,
  value : String,
) -> Unit {
  self.query.push((name, value))
}

///|
/// Supplies a decoded path capture; the client interpreter percent-encodes it.
pub fn RequestSink::set_capture(
  self : RequestSink,
  name : String,
  value : String,
) -> Unit {
  self.captures[name] = value
}

///|
/// Supplies the request body during client encoding.
pub fn RequestSink::set_body(self : RequestSink, body : @model.Body) -> Unit {
  self.body = body
}
