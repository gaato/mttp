enum Shape { Circle(Double); Square(Double) } derive(Debug, Eq)

let shape : JsonCodec[Shape] = tagged("Shape", "type", [
  case_("circle", object1("Circle", field("r", jdouble, r => r), r => r), s => match s { Circle(r) => Some(r); _ => None }, r => Circle(r)),
  case_("square", object1("Square", field("side", jdouble, r => r), r => r), s => match s { Square(x) => Some(x); _ => None }, x => Square(x)),
])

test "tagged union round trip and schema" {
  let j = (shape.to_)(Square(2.0))
  inspect(j.stringify(), content=(
    #|{"type":"square","side":2}
  ))
  assert_eq((shape.from_)(j), Square(2.0))
  let (_, comps) = components(shape.schema_)
  inspect(comps["Shape"].stringify(), content=(
    #|{"oneOf":[{"$ref":"#/components/schemas/Circle"},{"$ref":"#/components/schemas/Square"}],"discriminator":{"propertyName":"type","mapping":{"circle":"#/components/schemas/Circle","square":"#/components/schemas/Square"}}}
  ))
}
