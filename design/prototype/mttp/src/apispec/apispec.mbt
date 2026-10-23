///|
pub(all) struct Info {
  title : String
  version : String
} derive(ToJson, FromJson, Eq, Debug)

///|
pub(all) struct Server {
  url : String
} derive(ToJson, FromJson, Eq, Debug)

///|
pub(all) struct Parameter {
  name : String
  in_ : String
  required : Bool
  schema : Json
} derive(ToJson(fields(in_(rename="in"))), FromJson(fields(in_(rename="in"))), Eq, Debug)

///|
pub(all) struct MediaTypeObject {
  schema : Json
} derive(ToJson, FromJson, Eq, Debug)

///|
pub(all) struct HeaderObject {
  required : Bool
  schema : Json
} derive(ToJson, FromJson, Eq, Debug)

///|
pub(all) struct ResponseObject {
  description : String
  headers : Map[String, HeaderObject]
  content : Map[String, MediaTypeObject]
} derive(ToJson, FromJson, Eq, Debug)

///|
pub(all) struct RequestBody {
  required : Bool
  content : Map[String, MediaTypeObject]
} derive(ToJson, FromJson, Eq, Debug)

///|
pub(all) struct Operation {
  operationId : String?
  summary : String?
  parameters : Array[Parameter]
  requestBody : RequestBody?
  responses : Map[String, ResponseObject]
  security : Array[Map[String, Array[String]]]
} derive(ToJson, FromJson, Eq, Debug)

///|
pub(all) struct SecurityScheme {
  type_ : String
  scheme : String?
  name : String?
  in_ : String?
} derive(ToJson(fields(type_(rename="type"), in_(rename="in"))), FromJson(fields(type_(rename="type"), in_(rename="in"))), Eq, Debug)

///|
pub(all) struct Components {
  schemas : Map[String, Json]
  securitySchemes : Map[String, SecurityScheme]
} derive(ToJson, FromJson, Eq, Debug)

///|
pub(all) struct OpenApi {
  openapi : String
  info : Info
  servers : Array[Server]
  paths : Map[String, Map[String, Operation]]
  components : Components
} derive(ToJson, FromJson, Eq, Debug)
