///|
// OpenAPI requires unique (name, location) parameters and ignores three
// reserved header names. Refuse those descriptions rather than silently
// dropping constraints that the server still enforces.
fn add_parameter(
  parameters : Array[@apispec.Parameter],
  seen : Map[String, Bool],
  atom : @endpoint.Atom,
  location : String,
  schemas : Map[String, Json],
  problems : Array[@endpoint.DefinitionProblem],
  template : String,
) -> Unit {
  let name = if location == "header" { atom.name.to_lower() } else { atom.name }
  if location == "header" &&
    ["accept", "content-type", "authorization"].contains(name) {
    problems.push(
      @endpoint.DefinitionProblem::new(
        template,
        "OpenAPI ignores header parameter " + atom.name,
      ),
    )
    return
  }
  let key = location + " " + name
  if seen.contains(key) {
    problems.push(
      @endpoint.DefinitionProblem::new(
        template,
        "duplicate OpenAPI parameter " + key,
      ),
    )
    return
  }
  seen[key] = true
  parameters.push(
    @apispec.Parameter::new(
      atom.name,
      location,
      required=atom.required,
      schema=atom.schema.reference(schemas),
      description?=atom.description,
      extensions=if atom.rest { { "x-mttp-rest": true } } else { {} },
    ),
  )
}
