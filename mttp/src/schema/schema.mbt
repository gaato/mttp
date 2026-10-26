///|
/// A JSON Schema 2020-12 document (what OpenAPI 3.1 embeds), plus the name
/// it is hoisted under in `components/schemas` when it has one.
pub(all) struct Schema {
  name : String?
  json : Json // for a named schema: its definition body
  defs : Map[String, Json] // every named schema reachable from here (SC-01)
  problems : Array[String] // retained construction conflicts for definition checking
} derive(Eq, Debug)

///|
/// Creates an unnamed schema with no reachable definitions.
pub fn Schema::of(json : Json) -> Schema {
  { name: None, json, defs: {}, problems: [], }
}

///|
/// What a parent embeds for this child: a $ref for a named schema (its
/// definition and its own defs are merged into `into`), the body otherwise.
/// Conflicting names preserve the first definition and append to `problems`;
/// codec composition retains these findings for the shared endpoint checker.
pub fn Schema::reference(
  self : Schema,
  into : Map[String, Json],
  problems~ : Array[String] = [],
) -> Json {
  problems.append(self.problems)
  for k, v in self.defs {
    merge_definition(into, k, v, problems)
  }
  match self.name {
    Some(n) => {
      merge_definition(into, n, self.json, problems)
      { "$ref": Json("#/components/schemas/\{pointer_segment(n)}") }
    }
    None => self.json
  }
}

///|
fn merge_definition(
  into : Map[String, Json],
  name : String,
  value : Json,
  problems : Array[String],
) -> Unit {
  match into.get(name) {
    Some(previous) if previous != value =>
      problems.push("conflicting schema definition \{name}")
    _ => into[name] = value
  }
}

///|
/// Assigns the component name used by parent schema references.
pub fn Schema::named(self : Schema, name : String) -> Schema {
  { ..self, name: Some(name), }
}

///|
/// Adds JSON Schema keywords; validators use it so the document states
/// every constraint the decoder enforces.
pub fn Schema::patch(self : Schema, keywords : Map[String, Json]) -> Schema {
  match self.json {
    Object(m) => {
      let out = Map([])
      for k, v in m {
        out[k] = v
      }
      // Validators combine conjunctively: a keyword that is already set to
      // another value goes into allOf, so neither bound is lost.
      let conflicts = Map([])
      for k, v in keywords {
        match out.get(k) {
          Some(old) if old != v => conflicts[k] = v
          _ => out[k] = v
        }
      }
      if !conflicts.is_empty() {
        let all_of = match out.get("allOf") {
          Some(Array(xs)) => xs.copy()
          _ => []
        }
        all_of.push(Json::object(conflicts))
        out["allOf"] = Json::array(all_of)
      }
      { ..self, json: Json::object(out), }
    }
    _ =>
      { ..self, json: { "allOf": [self.json, Json::object(keywords.copy())] }, }
  }
}

///|
/// One problem with an input, located by JSON pointer.
pub(all) struct Issue {
  path : String
  code : String
  message : String
} derive(Eq, Debug, ToJson)

///|
/// Creates an issue at a JSON-pointer path, empty for the whole input.
pub fn Issue::new(
  code : String,
  message : String,
  path~ : String = "",
) -> Issue {
  { path, code, message, }
}

///|
/// Compares schemas including reachable definitions.
pub extend Schema with Eq::{equal, not_equal}

///|
/// Formats a schema for diagnostics.
pub extend Schema with @debug.Debug::{to_repr}

///|
/// Compares input issues.
pub extend Issue with Eq::{equal, not_equal}

///|
/// Formats an input issue.
pub extend Issue with @debug.Debug::{to_repr}

///|
/// Encodes the path, code and message fields.
pub extend Issue with ToJson::{to_json}
