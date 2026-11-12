# gaato/mttp_core/schema

Text, JSON and body codecs that carry their JSON Schema, and validators.

Codecs collect input issues with escaped JSON pointer paths. Named children
become references and retain their definitions.

```mbt check
///|
test {
  let age = @schema.int.validate(@schema.minimum(0))
  assert_eq(age.decode("42"), 42)
  let names = @schema.array(@schema.jstring).body()
  assert_eq(names.decode(b"[\"one\",\"two\"]"), ["one", "two"])
}
```

The codecs:

| Kind | Codecs |
|---|---|
| Text (paths, queries, headers) | `string`, `int`, `int64`, `double`, `bool`, `enum_of` |
| JSON scalars | `jstring`, `jint`, `jint64`, `jdouble`, `jbool`, `jvalue`, `string_enum`, `open_string` |
| JSON structures | `array`, `map_of`, `object1` to `object8` with `field`, `recursive`, `json()` for a type that implements `JsonSchema` |
| Unions | `tagged` (by a tag field) and `any_of` (the first case that decodes), with `case_` |
| Optional fields | `option`, `presence`, `omittable` |
| Bodies | `JsonCodec::body()`, `text_body`, `html_body`, `raw_bytes`, `form_body`, `form_codec` |
| Validators | `minimum`, `maximum`, `min_length`, `max_length`, `pattern`, `one_of_values`, `custom` |

`html_body` is a UTF-8 HTML page as a `String`, rendered with any template
engine.

`option` treats absent fields and explicit null alike; `presence` preserves
the distinction using `@jsonkit.Presence`. Both document the field as
nullable. `omittable` is for a field that may be left out but not set to
null: absent is `None`, null is refused with the child codec's usual issue at
the field's path, and the schema is the child's, not nullable. Object
encoders omit absent values, and none of the three fields is `required`.
`object1` through `object8` use typed getters and constructors.

Decoding untrusted JSON is bounded:

- JSON bodies refuse duplicate keys and nesting beyond 128, and keep number
  lexemes: `jint` and `jint64` check integrality and range on the lexeme, so
  `1.0000000000000001` is not the integer 1, and `jint64` represents the full
  signed range exactly.
- Recursive codecs cap decoding depth (128 by default).
- Every application of a codec to a JSON value is one step, and a decode takes
  at most 256 steps per value of its input (at least 4096) unless the caller
  passes `max_steps`. Past that it fails with `TooLarge`. An untagged union
  whose cases share a deep field would otherwise retry that subtree once per
  case at every level.
- Byte limits belong to the HTTP reader or the caller supplying buffered
  bytes.

Text codecs for numbers accept decimal syntax only: `int` and `int64` refuse
`0x10`, `0b1` and `1_000`, and `double` refuses `inf`, `NaN` and underscores.

`form_body` retains ordered duplicate pairs. Its wire schema admits either a
scalar string or a repeated string array for each form name, so OpenAPI form
serialization can describe duplicate values without losing that contract.

`form_codec` reads an HTML form into an object codec, so a form and a JSON API
share one definition, its validation and its JSON-pointer issue paths. Each
value is coerced by its property's schema type: decimal text for `integer`
and `number`; `true`, `false` or a checkbox's `on` for `boolean`; repeated
names for an array of scalars. Text that does not coerce, or a single-valued
name given twice, is an issue at that property's pointer. Browsers leave out
unchecked boxes and empty checkbox groups and cannot send `false` or `[]`, so
an absent required boolean is `false` and an absent required array `[]`;
absent optional properties stay absent, and a blank optional number is
absent. Names the schema does not list stay strings. A property that is an
object, an array of objects or a mix of types is a definition problem in the
schema's `problems`. Decoding reads at most 256 pairs, as `form_body` does.

```mbt check
///|
test {
  let contact = @schema.object3(
    "Contact",
    @schema.field("email", @schema.jstring, (c : (String, Int32, Bool)) => c.0),
    @schema.field("age", @schema.jint, c => c.1),
    @schema.field("subscribe", @schema.jbool, c => c.2),
    (email, age, subscribe) => (email, age, subscribe),
  )
  let form = @schema.form_codec(contact)
  assert_eq(
    form.decode(b"email=a%40b.c&age=30&subscribe=on"),
    ("a@b.c", 30, true),
  )
  // An unchecked box is not sent.
  assert_eq(form.decode(b"email=a%40b.c&age=30"), ("a@b.c", 30, false))
  assert_eq(
    form.encode(("a@b.c", 30, true)),
    b"email=a%40b.c&age=30&subscribe=true",
  )
}
```

`pattern` implements a bounded subset of ECMA Unicode pattern syntax without
flags, including group repetition. Its schema contains the original source.
It refuses unsupported syntax when built, including lookarounds,
backreferences and named groups; see the API documentation for the exact
limits. Dot excludes the four ECMA line terminators and whitespace escapes use
the ECMA whitespace set. The anchor behavior follows the
[ECMAScript assertion semantics](https://tc39.es/ecma262/multipage/text-processing.html#sec-compileassertion).

Union case projections and injections must be inverses and cover every value
passed to encoding. Tagged payload encoders must produce objects; violating
these application-side encoding preconditions aborts. A union with duplicate
tags or outside 1 to 64 cases records the problem in its schema's `problems`,
as conflicting definitions and duplicate object fields do; the endpoint
definition checker refuses such a schema.
