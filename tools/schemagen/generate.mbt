///|
struct Declaration {
  type_ : @syntax.TypeDecl
  attrs : Attributes
}

///|
fn codec_type(
  ty : @syntax.Type,
  declarations : Map[String, Declaration],
  self_name : String,
  self_used~ : Ref[Bool] = Ref(false),
  omittable~ : Bool = false,
  override_? : String,
) -> String raise GenerationError {
  if omittable && !(ty is Option(..)) {
    reject(ty.loc(), "#mttp.omittable requires T?")
  }
  match ty {
    Option(ty~, ..) => {
      let inner = codec_type(
        ty,
        declarations,
        self_name,
        self_used~,
        override_?,
      )
      "@schema.\{if omittable { "omittable" } else { "option" }}(\{inner})"
    }
    Name(constr_id~, tys~, ..) =>
      match constr_id.id {
        Dot(pkg="jsonkit", id="Presence") => {
          guard tys.to_array() is [inner] else {
            reject(ty.loc(), "Presence requires one type argument")
            return ""
          }
          "@schema.presence(\{codec_type(inner, declarations, self_name, self_used~, override_?)})"
        }
        _ =>
          match override_ {
            Some(value) => "(\{value})"
            None =>
              match (constr_id.id, tys.to_array()) {
                (Ident(name="Array"), [inner]) =>
                  "@schema.array(\{codec_type(inner, declarations, self_name, self_used~)})"
                (
                  Ident(name="Map"),
                  [
                    Name(
                      constr_id={ id: Ident(name="String"), .. },
                      tys=Empty,
                      ..
                    ),
                    inner,
                  ],
                ) =>
                  "@schema.map_of(\{codec_type(inner, declarations, self_name, self_used~)})"
                (Ident(name~), []) =>
                  match name {
                    "Int" | "Int32" => "@schema.jint"
                    "Int64" => "@schema.jint64"
                    "Double" => "@schema.jdouble"
                    "Bool" => "@schema.jbool"
                    "String" => "@schema.jstring"
                    "Json" => "@schema.jvalue"
                    _ if name == self_name => {
                      self_used.val = true
                      "self_codec"
                    }
                    _ if declarations.contains(name) => codec_name(name)
                    _ => {
                      reject(
                        ty.loc(),
                        "unknown type \{name}; use #mttp.codec(...)",
                      )
                      ""
                    }
                  }
                _ => {
                  reject(
                    ty.loc(),
                    "unsupported field type; use #mttp.codec(...)",
                  )
                  ""
                }
              }
          }
      }
    _ =>
      match override_ {
        Some(value) => "(\{value})"
        None => {
          reject(ty.loc(), "unsupported field type")
          ""
        }
      }
  }
}

///|
fn record_code(
  decl : Declaration,
  declarations : Map[String, Declaration],
  self_used : Ref[Bool],
) -> String raise GenerationError {
  let ty = decl.type_
  guard ty.components is Record(fields~, ..) else { return "" }
  guard fields.length() >= 1 && fields.length() <= 16 else {
    reject(ty.loc, "struct must have 1 to 16 fields")
    return ""
  }
  let name = decl.attrs.name.unwrap_or(ty.tycon)
  let out = StringBuilder()
  out.write_string("@schema.object\{fields.length()}(\{quoted(name)},\n")
  let names = []
  let wire_names : Map[String, Bool] = Map([])
  for field in fields {
    let attrs = attributes(field.attrs, on_type=false)
    let label = field.name.label
    let wire = attrs.rename.unwrap_or(label)
    if wire_names.contains(wire) {
      reject(field.loc, "duplicate JSON field \{wire}")
    }
    wire_names[wire] = true
    names.push(label)
    let override_ = attrs.codec
    let mut codec = codec_type(
      field.ty,
      declarations,
      ty.tycon,
      omittable=attrs.omittable,
      self_used~,
      override_?,
    )
    if !attrs.examples.is_empty() {
      codec += ".with_examples([\{attrs.examples.join(", ")}])"
    }
    if attrs.default_ is Some(value) {
      codec += ".with_default(\{value})"
    }
    let description = doc_text(field.doc)
    let extra = if description == "" {
      ""
    } else {
      ", description=\{quoted(description)}"
    }
    out.write_string(
      "@schema.field(\{quoted(wire)}, \{codec}, value => (value : \{ty.tycon}).\{label}\{extra}),\n",
    )
  }
  out.write_string("(\{names.join(", ")}) => { \{names.join(", ")}, },\n)")
  out.to_string()
}

///|
fn enum_code(
  decl : Declaration,
  declarations : Map[String, Declaration],
) -> String raise GenerationError {
  let ty = decl.type_
  guard ty.components is Variant(cases) else { return "" }
  guard !cases.is_empty() && cases.length() <= 64 else {
    reject(ty.loc, "enum must have 1 to 64 cases")
    return ""
  }
  let name = quoted(decl.attrs.name.unwrap_or(ty.tycon))
  let out = StringBuilder()
  if cases.iter().all(c => c.args is None) {
    let tags = cases.to_array().map(c => quoted(c.name.name))
    out.write_string(
      "@schema.string_enum(\{name}, [\{tags.join(", ")}]).map(value => match value {\n",
    )
    for c in cases {
      out.write_string(
        "\{quoted(c.name.name)} => \{ty.tycon}::\{c.name.name}\n",
      )
    }
    out.write_string(
      "_ => abort(\"string_enum checked membership\")\n}, value => match value {\n",
    )
    for c in cases {
      out.write_string(
        "\{ty.tycon}::\{c.name.name} => \{quoted(c.name.name)}\n",
      )
    }
    out.write_string("})")
  } else {
    out.write_string("@schema.tagged(\{name}, \"type\", [\n")
    for c in cases {
      let case_name = "\{ty.tycon}::\{c.name.name}"
      guard c.args is Some(More(arg, tail=Empty)) &&
        arg.label is None &&
        arg.ty is Name(constr_id={ id: Ident(name=payload), .. }, tys=Empty, ..) &&
        declarations.get(payload)
        is Some({ type_: { components: Record(..), .. }, .. }) else {
        reject(
          c.loc,
          "every tagged enum case must carry one annotated same-package struct",
        )
        continue
      }
      let codec = codec_type(arg.ty, declarations, ty.tycon)
      out.write_string(
        "@schema.case_(\{quoted(c.name.name)}, \{codec}, value => match value {\n\{case_name}(payload) => Some(payload)\n_ => None\n}, payload => \{case_name}(payload)),\n",
      )
    }
    out.write_string("])")
  }
  out.to_string()
}

///|
fn generate(sources : Array[(String, String)]) -> String raise GenerationError {
  let declarations : Map[String, Declaration] = Map([])
  for (path, source) in sources {
    let (items, reports) = @parser.parse_string(source, name=path)
    for report in reports {
      reject(report.loc, report.msg)
    }
    for item in items {
      if item is TopTypeDef(ty) {
        let attrs = attributes(ty.attrs, on_type=true)
        if !attrs.schema {
          continue
        }
        if !ty.params.is_empty() {
          reject(ty.loc, "generic schema types are unsupported")
        }
        if !(ty.components is (Record(..) | Variant(_))) {
          reject(
            ty.loc,
            "expected a struct or enum; tuple structs are unsupported",
          )
        }
        if declarations.contains(ty.tycon) {
          reject(ty.loc, "duplicate schema type \{ty.tycon}")
        }
        declarations[ty.tycon] = { type_: ty, attrs, }
      }
    }
  }
  let out = StringBuilder()
  out.write_string("// Generated by gaato/mttp_schemagen. Do not edit.\n")
  for _, decl in declarations {
    let ty = decl.type_
    let self_used = Ref(false)
    let mut body = match ty.components {
      Record(..) => record_code(decl, declarations, self_used)
      Variant(_) => enum_code(decl, declarations)
      _ => ""
    }
    if self_used.val {
      body = "@schema.recursive(\{quoted(decl.attrs.name.unwrap_or(ty.tycon))}, self_codec => \{body})"
    }
    let description = doc_text(ty.doc)
    if description != "" {
      body += ".with_description(\{quoted(description)})"
    }
    let visibility = if ty.type_vis is Pub(..) { "pub " } else { "" }
    out.write_string(
      "\n\{visibility}let \{codec_name(ty.tycon)} : @schema.JsonCodec[\{ty.tycon}] = \{body}\n",
    )
  }
  let (_, reports) = @parser.parse_string(out.to_string(), name="<generated>")
  for report in reports {
    reject(report.loc, report.msg)
  }
  out.to_string()
}
