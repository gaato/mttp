# gaato/mttp_schemagen

Generate JSON codecs, with their JSON Schema, from annotated MoonBit structs
and enums. The generated codecs are the ordinary `gaato/mttp_core/schema`
values that mttp endpoints use for validation and OpenAPI, so you write the
model once instead of a hand-written codec per type.

The generator is a command-line tool run with `moonx`. You check its output, a
plain `.mbt` file, into your repository, so reviewers see every change to the
wire format. Your program never depends on the generator or its parser.

## Install

Your package needs `gaato/mttp_core` 0.3.0 or later and imports
`gaato/mttp_core/schema`:

```sh
moon add gaato/mttp_core
```

Run the generator with `moonx`. Keep `moon`, `moonc` and `moonfmt` from the
same toolchain on your `PATH`, because the output is formatted and stamped with
that compiler's version.

## Generate a codec for a model

Put the annotated type in `model.mbt`:

```moonbit nocheck
///|
#mttp.schema
pub struct Note {
  /// A short title.
  title : String
  #mttp.nullable
  rating : Int32?
}
```

```sh
moonx gaato/mttp_schemagen@0.1.0 model_schema.mbt model.mbt
moon check --deny-warn
moonx gaato/mttp_schemagen@0.1.0 --check model_schema.mbt model.mbt
```

This writes `model_schema.mbt` with a public `note_codec`. Doc comments become
schema descriptions. The `rating` key is required and accepts JSON `null`.

- Arguments are `[--check] OUTPUT INPUT [INPUT ...]`. List every input file of
  one package, in a stable order.
- `moon check` is required: only the compiler can check custom codecs and
  defaults, so a successful generator run is not enough.
- `--check` compares the output byte for byte without writing, for CI.
- The tool replaces only a file it generated (marked on line 1), and refuses to
  overwrite anything else.
- After a toolchain upgrade, regenerate in the same change, because the header
  records the compiler version.

To regenerate automatically, add a rule to `moon.pkg`:

```moonbit nocheck
rule(
  name: "schema",
  command: "moonx gaato/mttp_schemagen@0.1.0 $output $input",
)
dev_build(rule: "schema", input: "model.mbt", output: "model_schema.mbt")
```

## How types map to codecs

| MoonBit type | Codec | JSON behaviour |
|---|---|---|
| `Int` / `Int32`, `Int64`, `Double`, `Bool`, `String`, `Json` | `jint`, `jint64`, `jdouble`, `jbool`, `jstring`, `jvalue` | |
| `Array[T]`, `Map[String, T]` | `array`, `map_of` | |
| `T?` | `option` | Absent and `null` both give `None`. `None` is omitted when encoding. |
| `T?` with `#mttp.omittable` | `omittable` | Absent gives `None`. `null` goes to `T`'s codec. |
| `T?` with `#mttp.nullable` | `nullable` | The key is required. `null` is `None`, and `None` encodes as `null`. |
| `@jsonkit.Presence[T]` | `presence` | Absent, `null` and a value stay distinct. |
| Another annotated type in the same package | its `<name>_codec` | |

## Attributes

- On a type: `#mttp.schema`, or `#mttp.schema(name="WireName")` to rename its
  schema component.
- On a field: `#mttp.rename("wire")`, `#mttp.codec(value)` for a hand-written
  validator, `#mttp.omittable` or `#mttp.nullable` (not both), repeatable
  `#mttp.example("<JSON text>")`, and `#mttp.schema_default(identifier)`.
  Examples and defaults only document the schema: a required field stays
  required, and nothing is filled in when decoding.
- For JSON names that are not valid MoonBit names, rename an escaped field:
  `#mttp.rename("true")` on `true_`.

Enums without arguments become string enums, and `#mttp.tag("wire")` sets a
case's string. Tagged enums wrap one annotated struct per case:

```moonbit nocheck
///|
#mttp.schema
#mttp.discriminator("kind")
enum Response {
  #mttp.tag("note-v1")
  Note(Note)
  #mttp.unknown
  Unknown(Json)
}
```

The discriminator defaults to `type`, and each tag to the case name. An
optional `#mttp.unknown` case keeps an object with an unknown tag whole and
encodes it back unchanged, so an older client can pass through newer data.
Known tags with invalid payloads still fail.

## Limits

- Structs have 1 to 16 named fields, the limit of `object16`. Enums have 1 to
  64 cases.
- Self-recursive structs are supported, but `schema_default` is refused on a
  field encoded through the recursive type. Use a hand-written codec there.
- Generics, tuple structs, mixed enums, duplicate wire names or tags, and
  malformed examples are errors, reported with `file:line:column`.

## Links

- [Generator source and fixtures](https://github.com/gaato/mttp/tree/main/mttp_schemagen)
- [`gaato/mttp_core`](https://mooncakes.io/docs/gaato/mttp_core): the schema
  codecs and endpoints that use the output
- [Changelog](https://github.com/gaato/mttp/blob/main/mttp_schemagen/CHANGELOG.md)

## License

[Apache-2.0](https://github.com/gaato/mttp/blob/main/LICENSE).
