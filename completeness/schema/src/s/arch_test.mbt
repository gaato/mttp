struct Address { city : String; zip : String }
struct User { name : String; address : Address }

let address : JsonCodec[Address] = object2("Address", field("city", jstring, a => a.city), field("zip", jstring, a => a.zip), (c, z) => { city: c, zip: z })
let user : JsonCodec[User] = object2("User", field("name", jstring, u => u.name), field("address", address, u => u.address), (n, a) => { name: n, address: a })

test "nested named schema is inlined; components only gets the top level" {
  let comps : Map[String, Json] = {}
  let _ = hoist(user.schema_, comps)
  inspect(comps.keys().collect(), content=(
    #|[User]
  ))
  inspect(comps["User"].stringify(), content=(
    #|{"type":"object","properties":{"name":{"type":"string"},"address":{"type":"object","properties":{"city":{"type":"string"},"zip":{"type":"string"}}}}}
  ))
}
