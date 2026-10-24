struct Address { city : String; zip : String }
struct User { name : String; address : Address }
struct Tree { label : String; children : Array[Tree] }

let address : JsonCodec[Address] = object2("Address", field("city", jstring, a => a.city), field("zip", jstring, a => a.zip), (c, z) => { city: c, zip: z })
let user : JsonCodec[User] = object2("User", field("name", jstring, u => u.name), field("address", address, u => u.address), (n, a) => { name: n, address: a })
let tree : JsonCodec[Tree] = recursive("Tree", self => object2("Tree", field("label", jstring, t => t.label), field("children", array(self), t => t.children), (l, c) => { label: l, children: c }))

test "nested named schemas are hoisted" {
  let (r, comps) = components(user.schema_)
  inspect(r.stringify(), content=(
    #|{"$ref":"#/components/schemas/User"}
  ))
  let keys = comps.keys().collect()
  keys.sort()
  inspect(keys, content=(
    #|[User, Address]
  ))
  inspect(comps["User"].stringify(), content=(
    #|{"type":"object","properties":{"name":{"type":"string"},"address":{"$ref":"#/components/schemas/Address"}}}
  ))
}

test "recursive type: schema and round trip" {
  let (r, comps) = components(tree.schema_)
  inspect(r.stringify(), content=(
    #|{"$ref":"#/components/schemas/Tree"}
  ))
  inspect(comps["Tree"].stringify(), content=(
    #|{"type":"object","properties":{"label":{"type":"string"},"children":{"type":"array","items":{"$ref":"#/components/schemas/Tree"}}}}
  ))
  let v : Tree = { label: "a", children: [{ label: "b", children: [] }] }
  let j = (tree.to_)(v)
  inspect(j.stringify(), content=(
    #|{"label":"a","children":[{"label":"b","children":[]}]}
  ))
  let back = (tree.from_)(j)
  inspect(back.children[0].label, content=(
    #|b
  ))
}
