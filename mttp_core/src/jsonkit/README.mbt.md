# gaato/mttp_core/jsonkit

Helpers for hand-written and generated JSON models.

They work with `moonbitlang/core`'s `Json`, `ToJson` and `FromJson`:

- `Presence[T]` keeps the three states of an optional property apart:
  omitted (`Absent`), `null` (`Null`) and a value (`Value`). An API that
  treats "leave unchanged" and "clear" differently needs all three.
- `ObjBuilder` writes an object field by field: `field` always, `opt` only
  for `Some`, `presence` omitting `Absent` and writing `null` for `Null`.
  Fields keep the position of their first write.
- `field`, `opt_field`, `presence_field` and `expect_object` decode an
  object's fields with the key added to the error path.
- `open_string` and `open_int` decode an enum that may grow on the server,
  keeping values this client does not know instead of failing.

The package is named `jsonkit`, not `json`, so its alias does not shadow
core's `@json`.

The decoders take the `JsonPath` that core hands a `FromJson` implementation,
so errors name the failing field:

```mbt check
///|
#derive(Eq, Debug)
struct Item {
  id : Int32
  note : @jsonkit.Presence[String]
  state : String
}

///|
impl FromJson for Item with fn from_json(json, path) {
  let obj = @jsonkit.expect_object(json, path)
  {
    id: @jsonkit.field(obj, "id", path),
    note: @jsonkit.presence_field(obj, "note", path),
    state: @jsonkit.open_string(
      obj.get("state").unwrap_or(Json::null()),
      path.add_key("state"),
      s => if s == "open" { Some(s) } else { None },
      s => "unknown:" + s,
    ),
  }
}

///|
impl ToJson for Item with fn to_json(self) {
  @jsonkit.ObjBuilder::new()
  .field("id", self.id)
  .presence("note", self.note)
  .field("state", self.state)
  .build()
}

///|
test "a model with a required, a nullable and an open field" {
  let item : Item = @json.from_json({
    "id": 7,
    "note": null,
    "state": "archived",
  })
  assert_eq(item, { id: 7, note: Null, state: "unknown:archived", })
  assert_eq(ToJson::to_json(item), {
    "id": 7,
    "note": null,
    "state": "unknown:archived",
  })
  let missing = try (@json.from_json({ "note": "x" }) : Item) catch {
    @json.JsonDecodeError((path, message)) => "\{path}: \{message}"
  } noraise {
    _ => "decoded"
  }
  assert_eq(missing, "/id: missing required field")
}
```
