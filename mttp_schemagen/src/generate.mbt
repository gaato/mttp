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
  self_binding~ : String = "self_codec",
  self_used~ : Ref[Bool] = Ref(false),
  omittable~ : Bool = false,
  nullable~ : Bool = false,
  override_? : String,
) -> String raise GenerationError {
  if (omittable || nullable) && !(ty is Option(..)) {
    reject(ty.loc(), "#mttp.omittable / #mttp.nullable requires T?")
  }
  match ty {
    Option(ty~, ..) => {
      let inner = codec_type(
        ty,
        declarations,
        self_name,
        self_binding~,
        self_used~,
        override_?,
      )
      let wrapper = if omittable {
        "omittable"
      } else if nullable {
        "nullable"
      } else {
        "option"
      }
      "@schema.\{wrapper}(\{inner})"
    }
    Name(constr_id~, tys~, ..) =>
      match constr_id.id {
        Dot(pkg="jsonkit", id="Presence") => {
          guard tys.to_array() is [inner] else {
            reject(ty.loc(), "Presence requires one type argument")
            return ""
          }
          "@schema.presence(\{codec_type(inner, declarations, self_name, self_binding~, self_used~, override_?)})"
        }
        _ =>
          match override_ {
            Some(value) => "(\{value})"
            None =>
              match (constr_id.id, tys.to_array()) {
                (Ident(name="Array"), [inner]) =>
                  "@schema.array(\{codec_type(inner, declarations, self_name, self_binding~, self_used~)})"
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
                  "@schema.map_of(\{codec_type(inner, declarations, self_name, self_binding~, self_used~)})"
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
                      self_binding
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
  local_prefix : String,
) -> String raise GenerationError {
  let ty = decl.type_
  guard ty.components is Record(fields~, ..) else { return "" }
  if decl.attrs.discriminator is Some(_) {
    reject(ty.loc, "discriminator is only supported on enums")
  }
  guard fields.length() >= 1 && fields.length() <= 16 else {
    reject(ty.loc, "struct must have 1 to 16 fields")
    return ""
  }
  let name = decl.attrs.name.unwrap_or(ty.tycon)
  let out = StringBuilder()
  out.write_string("@schema.object\{fields.length()}(\{quoted(name)},\n")
  let bindings = []
  let assignments = []
  let wire_names : Map[String, Bool] = Map([])
  for index, field in fields.to_array() {
    let attrs = attributes(field.attrs, on_type=false)
    let label = field.name.label
    let wire = attrs.rename.unwrap_or(label)
    if wire_names.contains(wire) {
      reject(field.loc, "duplicate JSON field \{wire}")
    }
    wire_names[wire] = true
    let binding = "\{local_prefix}field_\{index}"
    bindings.push(binding)
    assignments.push("\{label}: \{binding}")
    let override_ = attrs.codec
    let mut codec = codec_type(
      field.ty,
      declarations,
      ty.tycon,
      self_binding=local_prefix + "self_codec",
      omittable=attrs.omittable,
      nullable=attrs.nullable,
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
  out.write_string(
    "(\{bindings.join(", ")}) => { \{assignments.join(", ")}, },\n)",
  )
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
  let discriminator = decl.attrs.discriminator.unwrap_or("type")
  let tagged = cases.iter().any(c => c.args is Some(_))
  if !tagged && decl.attrs.discriminator is Some(_) {
    reject(ty.loc, "discriminator requires a tagged enum")
  }
  let known = []
  let tags : Map[String, Bool] = Map([])
  let mut fallback : String? = None
  for case_ in cases {
    let attrs = attributes(case_.attrs, on_type=false, on_case=true)
    if attrs.unknown {
      if !tagged ||
        fallback is Some(_) ||
        attrs.tag is Some(_) ||
        !(case_.args
        is Some(
          More(
            {
              ty: Name(constr_id={ id: Ident(name="Json"), .. }, tys=Empty, ..),
              label: None,
              ..
            },
            tail=Empty
          )
        )) {
        reject(
          case_.loc,
          "one #mttp.unknown case carrying exactly one unlabeled Json is allowed on a tagged enum",
        )
      }
      fallback = Some(case_.name.name)
    } else {
      let tag = attrs.tag.unwrap_or(case_.name.name)
      if tags.contains(tag) {
        reject(case_.loc, "duplicate wire tag \{tag}")
      }
      tags[tag] = true
      known.push((case_, tag))
    }
  }
  if known.is_empty() {
    reject(ty.loc, "enum requires a known case")
  }
  let out = StringBuilder()
  if !tagged {
    let tags = known.map(pair => quoted(pair.1))
    out.write_string(
      "@schema.string_enum(\{name}, [\{tags.join(", ")}]).map(value => match value {\n",
    )
    for (c, tag) in known {
      out.write_string("\{quoted(tag)} => \{ty.tycon}::\{c.name.name}\n")
    }
    out.write_string(
      "_ => abort(\"string_enum checked membership\")\n}, value => match value {\n",
    )
    for (c, tag) in known {
      out.write_string("\{ty.tycon}::\{c.name.name} => \{quoted(tag)}\n")
    }
    out.write_string("})")
  } else {
    out.write_string("@schema.tagged(\{name}, \{quoted(discriminator)}, [\n")
    for (c, tag) in known {
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
      if declarations.get(payload)
        is Some({ type_: { components: Record(fields~, ..), .. }, .. }) {
        for field in fields {
          let attrs = attributes(field.attrs, on_type=false)
          if attrs.rename.unwrap_or(field.name.label) == discriminator {
            reject(
              field.loc,
              "payload field collides with discriminator \{discriminator}",
            )
          }
        }
      }
      let other = if known.length() == 1 && fallback is None {
        ""
      } else {
        "_ => None\n"
      }
      out.write_string(
        "@schema.case_(\{quoted(tag)}, \{codec}, value => match value {\n\{case_name}(payload) => Some(payload)\n\{other}}, payload => \{case_name}(payload)),\n",
      )
    }
    out.write_string("],")
    if fallback is Some(case_name) {
      let case_constructor = "\{ty.tycon}::\{case_name}"
      out.write_string(
        "unknown=@schema.jvalue.map(json => \{case_constructor}(json), value => match value {\n\{case_constructor}(json) => json\n_ => abort(\"known union projections cover this value\")\n}),",
      )
    }
    out.write_string(")")
  }
  out.to_string()
}

///|
fn generate(
  sources : Array[(String, String)],
  toolchain~ : String = "test",
) -> String raise GenerationError {
  let declarations : Map[String, Declaration] = Map([])
  let existing : Map[String, Bool] = Map([])
  for (path, source) in sources {
    let (items, reports) = @parser.parse_string(source, name=path)
    for report in reports {
      reject(report.loc, report.msg)
    }
    for item in items {
      match item {
        TopLetDef(binder~, ..) => existing[binder.name] = true
        TopFuncDef(fun_decl~, ..) if fun_decl.type_name is None =>
          existing[fun_decl.name.name] = true
        _ => ()
      }
      if item is TopTypeDef(ty) {
        let attrs = attributes(ty.attrs, on_type=true)
        if !attrs.schema {
          if contains_mttp_attribute(ToJson::to_json(item)) {
            reject(ty.loc, "#mttp attributes require #mttp.schema on the type")
          }
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
        if ty.components is Record(constr_decl=Some(_), ..) {
          reject(ty.loc, "custom struct constructors are unsupported")
        }
        if declarations.contains(ty.tycon) {
          reject(ty.loc, "duplicate schema type \{ty.tycon}")
        }
        declarations[ty.tycon] = { type_: ty, attrs, }
      } else if contains_mttp_attribute(ToJson::to_json(item)) {
        reject(
          item.loc(),
          "#mttp attributes are unsupported on this declaration",
        )
      }
    }
  }
  for _, declaration in declarations {
    let binding = codec_name(declaration.type_.tycon)
    if existing.contains(binding) {
      reject(
        declaration.type_.loc,
        "generated binding \{binding} already exists in the input package",
      )
    }
  }
  validate_dependencies(declarations)
  let mut local_prefix = "mttp_generated_"
  while sources.iter().any(pair => pair.1.contains(local_prefix)) ||
        declarations
        .values()
        .any(decl => codec_name(decl.type_.tycon).has_prefix(local_prefix)) {
    local_prefix += "_"
  }
  let out = StringBuilder()
  out.write_string(
    "\{generated_marker} v\{tool_version}; moonc \{toolchain}. Do not edit.\n",
  )
  for _, decl in declarations {
    let ty = decl.type_
    let self_used = Ref(false)
    let mut body = match ty.components {
      Record(..) => record_code(decl, declarations, self_used, local_prefix)
      Variant(_) => enum_code(decl, declarations)
      _ => ""
    }
    if self_used.val {
      body = "@schema.recursive(\{quoted(decl.attrs.name.unwrap_or(ty.tycon))}, \{local_prefix}self_codec => \{body})"
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

///|
fn contains_mttp_attribute(value : Json) -> Bool {
  match value {
    Object(fields) => {
      if fields.get("kind") is Some(String("Attribute")) &&
        fields.get("children") is Some(Object(children)) &&
        children.get("raw") is Some(String(raw)) &&
        raw.has_prefix("#mttp.") {
        return true
      }
      fields.values().any(contains_mttp_attribute)
    }
    Array(values) => values.iter().any(contains_mttp_attribute)
    _ => false
  }
}
