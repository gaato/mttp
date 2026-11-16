///|
/// Which message a change affects. A request is read by the server and
/// written by the caller; a response is read by the caller.
#derive(Eq, Debug)
pub(all) enum Side {
  Request
  Response
}

///|
/// How much a change matters to one reader.
#derive(Eq, Debug)
pub(all) enum Severity {
  /// A reader written against the old document can fail.
  Breaking
  /// A reader may notice; whether it fails depends on how it was written.
  Warning
  /// Nothing written against the old document stops working.
  Info
}

///|
/// The reader whose expectations decide a change's severity.
#derive(Eq, Debug)
pub(all) enum View {
  /// A client generated from the old document, decoding responses strictly:
  /// a value it has no case for, such as a new response enum value, breaks
  /// it. moonbit-sdks' spec-watch reads this view.
  Client
  /// The provider's view, as oasdiff takes it: a caller tolerates values it
  /// does not know, and a change breaks only what the old document promised.
  Server
}

///|
/// What changed. A kind names the change; the change's `path` says where.
/// String payloads are the document's own spelling: a parameter location is
/// its `in` value, a status its `responses` key.
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum ChangeKind {
  PathAdded
  PathRemoved
  OperationAdded(meth~ : String)
  OperationRemoved(meth~ : String)
  /// `operationId` changed: the wire is the same, a generated method's name
  /// is not.
  OperationIdChanged(old~ : String?, new~ : String?)
  ParameterAdded(name~ : String, location~ : String, required~ : Bool)
  ParameterRemoved(name~ : String, location~ : String)
  /// `required` now has this value.
  ParameterRequiredChanged(name~ : String, location~ : String, required~ : Bool)
  ParameterLocationChanged(name~ : String, old~ : String, new~ : String)
  RequestBodyAdded(required~ : Bool)
  RequestBodyRemoved
  /// `required` now has this value.
  RequestBodyRequiredChanged(required~ : Bool)
  MediaTypeAdded(media_type~ : String)
  MediaTypeRemoved(media_type~ : String)
  ResponseAdded(status~ : String)
  ResponseRemoved(status~ : String)
  /// One alternative of the operation's effective `security` list: scheme
  /// names with their scopes. An empty map is anonymous access.
  SecurityRequirementAdded(requirement~ : Map[String, Array[String]])
  SecurityRequirementRemoved(requirement~ : Map[String, Array[String]])
  ServerAdded(url~ : String)
  ServerRemoved(url~ : String)
  /// The JSON Schema `type` set changed, beyond `"null"`. An empty array is
  /// a schema without `type`.
  TypeChanged(old~ : Array[String], new~ : Array[String])
  /// `"null"` joined the `type` array.
  NullableAdded
  /// `"null"` left the `type` array.
  NullableRemoved
  FormatChanged(old~ : String?, new~ : String?)
  EnumValueAdded(value~ : Json)
  EnumValueRemoved(value~ : Json)
  /// An `enum` now restricts a schema that had none.
  EnumAdded
  /// The schema's `enum` restriction is gone.
  EnumRemoved
  PropertyAdded(name~ : String)
  PropertyRemoved(name~ : String)
  RequiredPropertyAdded(name~ : String)
  RequiredPropertyRemoved(name~ : String)
  /// `additionalProperties` in its boolean form (absent is `true`) changed
  /// between allowing and refusing other members, or between a boolean and
  /// a schema. `None` is absent.
  AdditionalPropertiesChanged(old~ : Json?, new~ : Json?)
  /// One of `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`,
  /// `minLength`, `maxLength`, `minItems`, `maxItems`, `minProperties`,
  /// `maxProperties`, with numeric values.
  BoundChanged(keyword~ : String, old~ : Json?, new~ : Json?)
  /// A subschema of `oneOf`, `anyOf` or `allOf` at `index` (in the new
  /// document for an addition, the old one for a removal).
  SubschemaAdded(keyword~ : String, index~ : Int32)
  SubschemaRemoved(keyword~ : String, index~ : Int32)
  /// A schema's `$ref` names another target, or a reference replaced an
  /// inline schema (`None`) or the reverse. The targets are compared too.
  RefTargetChanged(old~ : String?, new~ : String?)
  /// A keyword outside the specialized kinds. Schema values, including 3.0
  /// `nullable` and boolean `exclusiveMinimum`, are compared as JSON without
  /// 3.0 interpretation. Parameter serialization settings carry effective
  /// defaults. `unresolved-ref` is a warning diagnostic for a skipped target.
  KeywordChanged(keyword~ : String, old~ : Json?, new~ : Json?)
  /// The comparison spent its node budget and stopped here; the report is
  /// incomplete.
  LimitReached(max_nodes~ : Int32)
}

///|
/// One difference between the documents.
///
/// `path` is a JSON Pointer (RFC 6901) into the new document, or into the
/// old one for something only the old document has. A change inside a schema
/// reached through `$ref` is reported once per side and conservative context,
/// at the referenced schema's own location.
#derive(Eq, Debug)
pub struct Change {
  side : Side
  path : String
  kind : ChangeKind
  client : Severity
  server : Severity
}

///|
/// The severity of the change to `view`'s reader.
pub fn Change::severity(self : Change, view : View) -> Severity {
  match view {
    Client => self.client
    Server => self.server
  }
}

///|
/// The differences between two documents, request side and response side
/// apart, each in document order.
#derive(Eq, Debug)
pub struct Report {
  request : Array[Change]
  response : Array[Change]
}

///|
/// The changes of both sides that `view`'s reader sees as `Breaking`.
pub fn Report::breaking(self : Report, view : View) -> Array[Change] {
  self.request
  .iter()
  .concat(self.response.iter())
  .filter(change => change.severity(view) is Breaking)
  .collect()
}

///|
/// Whether the comparison finished within its node budget. An incomplete
/// report holds a `LimitReached` change where it stopped.
pub fn Report::complete(self : Report) -> Bool {
  !self.request
  .iter()
  .concat(self.response.iter())
  .any(change => change.kind is LimitReached(..))
}

///|
/// Encode the message side as a lowercase JSON string.
pub impl ToJson for Side with fn to_json(self) {
  match self {
    Request => "request"
    Response => "response"
  }
}

///|
/// Encode the severity as a lowercase JSON string.
pub impl ToJson for Severity with fn to_json(self) {
  match self {
    Breaking => "breaking"
    Warning => "warning"
    Info => "info"
  }
}

///|
/// The kind's name, kebab-case, as `ToJson` writes it.
pub fn ChangeKind::name(self : ChangeKind) -> String {
  match self {
    PathAdded => "path-added"
    PathRemoved => "path-removed"
    OperationAdded(..) => "operation-added"
    OperationRemoved(..) => "operation-removed"
    OperationIdChanged(..) => "operation-id-changed"
    ParameterAdded(..) => "parameter-added"
    ParameterRemoved(..) => "parameter-removed"
    ParameterRequiredChanged(..) => "parameter-required-changed"
    ParameterLocationChanged(..) => "parameter-location-changed"
    RequestBodyAdded(..) => "request-body-added"
    RequestBodyRemoved => "request-body-removed"
    RequestBodyRequiredChanged(..) => "request-body-required-changed"
    MediaTypeAdded(..) => "media-type-added"
    MediaTypeRemoved(..) => "media-type-removed"
    ResponseAdded(..) => "response-added"
    ResponseRemoved(..) => "response-removed"
    SecurityRequirementAdded(..) => "security-requirement-added"
    SecurityRequirementRemoved(..) => "security-requirement-removed"
    ServerAdded(..) => "server-added"
    ServerRemoved(..) => "server-removed"
    TypeChanged(..) => "type-changed"
    NullableAdded => "nullable-added"
    NullableRemoved => "nullable-removed"
    FormatChanged(..) => "format-changed"
    EnumValueAdded(..) => "enum-value-added"
    EnumValueRemoved(..) => "enum-value-removed"
    EnumAdded => "enum-added"
    EnumRemoved => "enum-removed"
    PropertyAdded(..) => "property-added"
    PropertyRemoved(..) => "property-removed"
    RequiredPropertyAdded(..) => "required-property-added"
    RequiredPropertyRemoved(..) => "required-property-removed"
    AdditionalPropertiesChanged(..) => "additional-properties-changed"
    BoundChanged(..) => "bound-changed"
    SubschemaAdded(..) => "subschema-added"
    SubschemaRemoved(..) => "subschema-removed"
    RefTargetChanged(..) => "ref-target-changed"
    KeywordChanged(..) => "keyword-changed"
    LimitReached(..) => "limit-reached"
  }
}

///|
fn strings_json(values : Array[String]) -> Json {
  Json::array(values.map(value => Json::string(value)))
}

///|
fn optional_json(value : Json?) -> Json {
  match value {
    Some(value) => value
    None => Json::null()
  }
}

///|
fn optional_string(value : String?) -> Json {
  match value {
    Some(value) => Json::string(value)
    None => Json::null()
  }
}

///|
/// Writes the kind's details into `obj`, under `kind`'s own member names.
fn ChangeKind::add_details(self : ChangeKind, obj : Map[String, Json]) -> Unit {
  match self {
    PathAdded
    | PathRemoved
    | RequestBodyRemoved
    | NullableAdded
    | NullableRemoved
    | EnumAdded
    | EnumRemoved => ()
    OperationAdded(meth~) | OperationRemoved(meth~) =>
      obj["method"] = Json::string(meth)
    OperationIdChanged(old~, new~) | FormatChanged(old~, new~) => {
      obj["old"] = optional_string(old)
      obj["new"] = optional_string(new)
    }
    ParameterAdded(name~, location~, required~)
    | ParameterRequiredChanged(name~, location~, required~) => {
      obj["name"] = Json::string(name)
      obj["in"] = Json::string(location)
      obj["required"] = Json::boolean(required)
    }
    ParameterRemoved(name~, location~) => {
      obj["name"] = Json::string(name)
      obj["in"] = Json::string(location)
    }
    ParameterLocationChanged(name~, old~, new~) => {
      obj["name"] = Json::string(name)
      obj["old"] = Json::string(old)
      obj["new"] = Json::string(new)
    }
    RequestBodyAdded(required~) | RequestBodyRequiredChanged(required~) =>
      obj["required"] = Json::boolean(required)
    MediaTypeAdded(media_type~) | MediaTypeRemoved(media_type~) =>
      obj["mediaType"] = Json::string(media_type)
    ResponseAdded(status~) | ResponseRemoved(status~) =>
      obj["status"] = Json::string(status)
    SecurityRequirementAdded(requirement~)
    | SecurityRequirementRemoved(requirement~) =>
      obj["requirement"] = Json::object(
        requirement.map((_, scopes) => strings_json(scopes)),
      )
    ServerAdded(url~) | ServerRemoved(url~) => obj["url"] = Json::string(url)
    TypeChanged(old~, new~) => {
      obj["old"] = strings_json(old)
      obj["new"] = strings_json(new)
    }
    EnumValueAdded(value~) | EnumValueRemoved(value~) => obj["value"] = value
    PropertyAdded(name~)
    | PropertyRemoved(name~)
    | RequiredPropertyAdded(name~)
    | RequiredPropertyRemoved(name~) => obj["name"] = Json::string(name)
    AdditionalPropertiesChanged(old~, new~) => {
      obj["old"] = optional_json(old)
      obj["new"] = optional_json(new)
    }
    BoundChanged(keyword~, old~, new~) | KeywordChanged(keyword~, old~, new~) => {
      obj["keyword"] = Json::string(keyword)
      obj["old"] = optional_json(old)
      obj["new"] = optional_json(new)
    }
    SubschemaAdded(keyword~, index~) | SubschemaRemoved(keyword~, index~) => {
      obj["keyword"] = Json::string(keyword)
      obj["index"] = Json::number(index.to_double())
    }
    RefTargetChanged(old~, new~) => {
      obj["old"] = optional_string(old)
      obj["new"] = optional_string(new)
    }
    LimitReached(max_nodes~) =>
      obj["maxNodes"] = Json::number(max_nodes.to_double())
  }
}

///|
/// Encode the kind name and its payload as a JSON object.
pub impl ToJson for ChangeKind with fn to_json(self) {
  let obj : Map[String, Json] = { "kind": Json::string(self.name()) }
  self.add_details(obj)
  Json::object(obj)
}

///|
/// `{ "path", "kind", "client", "server", ...details }`: the kind's details
/// follow its name, as `ChangeKind`'s JSON writes them.
pub impl ToJson for Change with fn to_json(self) {
  let obj : Map[String, Json] = {
    "path": Json::string(self.path),
    "kind": Json::string(self.kind.name()),
    "client": self.client.to_json(),
    "server": self.server.to_json(),
  }
  self.kind.add_details(obj)
  Json::object(obj)
}

///|
/// `{ "request": [...], "response": [...] }`.
pub impl ToJson for Report with fn to_json(self) {
  {
    "request": Json::array(self.request.map(change => change.to_json())),
    "response": Json::array(self.response.map(change => change.to_json())),
  }
}

///|
/// Compare values structurally.
pub extend Side with Eq::{equal, not_equal}

///|
/// Render a structural debugging representation.
pub extend Side with @debug.Debug::{to_repr}

///|
/// Compare values structurally.
pub extend Severity with Eq::{equal, not_equal}

///|
/// Render a structural debugging representation.
pub extend Severity with @debug.Debug::{to_repr}

///|
/// Compare values structurally.
pub extend View with Eq::{equal, not_equal}

///|
/// Render a structural debugging representation.
pub extend View with @debug.Debug::{to_repr}

///|
/// Compare values structurally.
pub extend ChangeKind with Eq::{equal, not_equal}

///|
/// Render a structural debugging representation.
pub extend ChangeKind with @debug.Debug::{to_repr}

///|
/// Compare values structurally.
pub extend Change with Eq::{equal, not_equal}

///|
/// Render a structural debugging representation.
pub extend Change with @debug.Debug::{to_repr}

///|
/// Compare values structurally.
pub extend Report with Eq::{equal, not_equal}

///|
/// Render a structural debugging representation.
pub extend Report with @debug.Debug::{to_repr}

///|
/// Render the documented JSON representation.
pub extend Side with ToJson::{to_json}

///|
/// Render the documented JSON representation.
pub extend Severity with ToJson::{to_json}

///|
/// Render the documented JSON representation.
pub extend ChangeKind with ToJson::{to_json}

///|
/// Render the documented JSON representation.
pub extend Change with ToJson::{to_json}

///|
/// Render the documented JSON representation.
pub extend Report with ToJson::{to_json}
