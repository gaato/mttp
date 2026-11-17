///|
fn referenced_types(ty : @syntax.Type, output : Array[String]) -> Unit {
  match ty {
    Name(constr_id~, tys~, ..) => {
      if constr_id.id is Ident(name~) {
        output.push(name)
      }
      for child in tys {
        referenced_types(child, output)
      }
    }
    Option(ty~, ..) => referenced_types(ty, output)
    _ => ()
  }
}

///|
// Self recursion has a schema.recursive proxy; cross-type cycles have no
// such proxy and must not become cyclic top-level initializers.
fn validate_dependencies(
  declarations : Map[String, Declaration],
) -> Unit raise GenerationError {
  let graph : Map[String, Array[String]] = Map([])
  for name, declaration in declarations {
    let references = []
    match declaration.type_.components {
      Record(fields~, ..) =>
        for field in fields {
          if attributes(field.attrs, on_type=false).codec is None {
            referenced_types(field.ty, references)
          }
        }
      Variant(cases) =>
        for case_ in cases {
          if case_.args is Some(args) {
            for arg in args {
              referenced_types(arg.ty, references)
            }
          }
        }
      _ => ()
    }
    graph[name] = references.filter(other => {
      other != name && declarations.contains(other)
    })
  }
  let active : Map[String, Bool] = Map([])
  let done : Map[String, Bool] = Map([])
  fn visit(name : String) -> Unit raise GenerationError {
    if active.get(name) == Some(true) {
      reject(
        declarations[name].type_.loc,
        "mutual recursion is unsupported; supply a hand-written codec",
      )
    }
    if done.contains(name) {
      return
    }
    active[name] = true
    for other in graph[name] {
      visit(other)
    }
    active[name] = false
    done[name] = true
  }
  for name, _ in declarations {
    visit(name)
  }
}
