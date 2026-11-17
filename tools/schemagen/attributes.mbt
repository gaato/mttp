///|
#derive(Debug)
suberror GenerationError {
  Invalid(String)
}

///|
fn reject(
  loc : @basic.Location,
  message : String,
) -> Unit raise GenerationError {
  raise Invalid(
    "\{loc.start.fname}:\{loc.start.lnum}:\{loc.start.cnum - loc.start.bol + 1}: \{message}",
  )
}

///|
fn quoted(value : String) -> String {
  Json::string(value).stringify()
}

///|
fn doc_text(doc : @syntax.DocString) -> String {
  doc.content
  .to_array()
  .map(line => line.trim().to_owned())
  .join("\n")
  .trim()
  .to_owned()
}

///|
struct Attributes {
  mut schema : Bool
  mut name : String?
  mut rename : String?
  mut codec : String?
  mut omittable : Bool
  examples : Array[String]
  mut default_ : String?
}

///|
fn attributes(
  attrs : @list.List[@attribute.Attribute],
  on_type~ : Bool,
) -> Attributes raise GenerationError {
  let result = Attributes::{
    schema: false,
    name: None,
    rename: None,
    codec: None,
    omittable: false,
    examples: [],
    default_: None,
  }
  let seen : Map[String, Bool] = Map([])
  for attr in attrs {
    if !attr.raw.has_prefix("#mttp.") {
      continue
    }
    let raw = attr.raw
    let open = raw.find("(")
    let name = raw[6:open.unwrap_or(raw.length())].to_owned()
    if name != "example" && seen.contains(name) {
      reject(attr.loc, "duplicate #mttp.\{name}")
    }
    seen[name] = true
    let payload = match open {
      Some(start) if raw.has_suffix(")") =>
        raw[start + 1:raw.length() - 1].trim().to_owned()
      None => ""
      _ => {
        reject(attr.loc, "malformed attribute")
        ""
      }
    }
    fn string_payload() -> String raise GenerationError {
      let value = @json.parse(payload) catch { _ => Json::null() }
      match value {
        String(s) => s
        _ => {
          reject(attr.loc, "#mttp.\{name} requires a string literal")
          ""
        }
      }
    }
    match name {
      "schema" if on_type => {
        result.schema = true
        if open is Some(_) {
          match attr.parsed {
            Some(Apply(_, More(Labeled("name", String(value)), tail=Empty))) =>
              result.name = Some(value)
            _ => reject(attr.loc, "expected #mttp.schema(name=\"...\")")
          }
        }
      }
      "rename" if !on_type => result.rename = Some(string_payload())
      "codec" if !on_type && payload != "" => result.codec = Some(payload)
      "omittable" if !on_type && open is None => result.omittable = true
      "example" if !on_type => {
        let text = string_payload()
        let value = @json.parse(text) catch {
          _ => {
            reject(attr.loc, "example is not valid JSON")
            Json::null()
          }
        }
        result.examples.push(value.stringify())
      }
      "default" if !on_type =>
        match attr.parsed {
          Some(Apply(_, More(Expr(Ident(id)), tail=Empty))) =>
            result.default_ = Some(Show::to_string(id))
          _ => reject(attr.loc, "default requires an identifier")
        }
      _ => reject(attr.loc, "unsupported #mttp.\{name} on this declaration")
    }
  }
  result
}

///|
fn codec_name(name : String) -> String {
  let out = StringBuilder()
  for i, c in name {
    if c >= 'A' && c <= 'Z' {
      if i > 0 {
        out.write_string("_")
      }
      out.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      out.write_char(c)
    }
  }
  out.to_string() + "_codec"
}
