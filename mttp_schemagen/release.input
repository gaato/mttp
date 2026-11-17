///|
#derive(Eq, Debug)
#mttp.schema
struct CollisionFields {
  #mttp.rename("true")
  true_ : Bool
  #mttp.rename("false")
  false_ : Bool
  #mttp.rename("None")
  none_ : String
  #mttp.rename("Json")
  json_ : String
  value : Int32
  self_codec : Int32
  mttp_field_0 : Int32
  mttp_generated_field_0 : Int32
  #mttp.nullable
  nullable_value : String?
  #mttp.schema_default(documented_count)
  count : Int32
}

///|
let documented_count : Int32 = 9

///|
let mttp_generated_self_codec : Int32 = 2

///|
#derive(Eq, Debug)
#mttp.schema
struct RecursiveCollision {
  next : RecursiveCollision?
  #mttp.schema_default(mttp_generated_self_codec)
  weight : Int32
}

///|
#mttp.schema
#mttp.discriminator("event/kind")
enum ServerEvent {
  #mttp.tag("changed-v1")
  Changed(CollisionFields)
  #mttp.tag("deleted-v2")
  Deleted(CollisionFields)
  #mttp.unknown
  Unknown(Json)
}

///|
#mttp.schema
enum SingleServerEvent {
  Only(CollisionFields)
}

///|
test "generated reserved wire names required nulls and documentation defaults compile and round trip" {
  let input : Json = {
    "true": true,
    "false": false,
    "None": "none",
    "Json": "json",
    "value": 1,
    "self_codec": 2,
    "mttp_field_0": 3,
    "mttp_generated_field_0": 4,
    "nullable_value": null,
    "count": 4,
  }
  let value = collision_fields_codec.from_json(input)
  assert_eq(value.nullable_value, None)
  assert_eq(value.count, 4)
  assert_eq(collision_fields_codec.to_json(value), input)
  let missing : Json = {
    "true": true,
    "false": false,
    "None": "none",
    "Json": "json",
    "value": 1,
    "self_codec": 2,
    "mttp_field_0": 3,
    "mttp_generated_field_0": 4,
  }
  let issues = try {
    ignore(collision_fields_codec.from_json(missing))
    []
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) => issues
    other => fail("unexpected error: \{other}")
  }
  assert_eq(issues.map(issue => issue.path), ["/nullable_value", "/count"])
  let schema = collision_fields_codec.schema().json
  guard schema is Object(object) && object["properties"] is Object(properties) else {
    fail("object schema expected")
  }
  assert_eq(properties["count"], {
    "type": "integer",
    "format": "int32",
    "default": 9,
  })
  let recursive = RecursiveCollision::{ next: None, weight: 2, }
  assert_eq(
    recursive_collision_codec.from_json(
      recursive_collision_codec.to_json(recursive),
    ),
    recursive,
  )
}

///|
test "generated tagged response fallback preserves unknown JSON without masking known validation errors" {
  let unknown : Json = { "event/kind": "future", "payload": [1, null, "hello"] }
  guard server_event_codec.from_json(unknown) is Unknown(raw) else {
    fail("expected unknown response")
  }
  assert_eq(raw, unknown)
  assert_eq(server_event_codec.to_json(Unknown(raw)), unknown)
  let known : Json = {
    "event/kind": "changed-v1",
    "true": true,
    "false": false,
    "None": "none",
    "Json": "json",
    "value": 1,
    "self_codec": 2,
    "mttp_field_0": 3,
    "mttp_generated_field_0": 4,
    "nullable_value": null,
    "count": 4,
  }
  guard server_event_codec.from_json(known) is Changed(value) else {
    fail("expected known response")
  }
  assert_eq(server_event_codec.to_json(Changed(value)), known)
  let only = single_server_event_codec.to_json(Only(value))
  let Only(decoded) = single_server_event_codec.from_json(only)
  assert_eq(decoded, value)
  let budget_stopped = try {
    ignore(server_event_codec.from_json(known, max_steps=1))
    false
  } catch {
    @schema.DecodeFailure(kind=TooLarge(limit=1), ..) => true
    _ => false
  }
  assert_true(budget_stopped)
  let invalid : Array[Json] = [
    { "event/kind": "changed-v1" },
    {},
    { "event/kind": null },
    null,
  ]
  for input in invalid {
    assert_true(
      try {
        ignore(server_event_codec.from_json(input))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(server_event_codec.schema().problems, [])
  guard server_event_codec.schema().json is Object(keywords) &&
    keywords["discriminator"] is Object(discriminator) &&
    discriminator["mapping"] is Object(mapping) &&
    keywords["oneOf"] is Array(alternatives) else {
    fail("tagged schema expected")
  }
  assert_eq(mapping["deleted-v2"], "#/components/schemas/ServerEvent/oneOf/1")
  assert_eq(alternatives.length(), 3)
}
