# gaato/mttp_schemagen

Generate ordinary `@schema.object1` to `object16`, enum and recursive codecs
from annotated MoonBit types. Check the generated `<name>_schema.mbt` into
source control. The consumer needs **gaato/mttp_core 0.2.1 or later**: registry
0.2.0 predates `field(description?)`, `with_description`, `nullable` and
`tagged(unknown?)`.
The local checkout supplies these APIs until that core release is published.

## Install

The generator is a separate Wasm executable. Its parser dependency never
enters the consumer's module graph. Keep `moon`, `moonc` and `moonfmt` from
the same toolchain on PATH, because output formatting and the recorded
compiler version belong together.

```sh
moonx gaato/mttp_schemagen@0.1.0 model_schema.mbt model.mbt
moon check --deny-warn
moonx gaato/mttp_schemagen@0.1.0 --check model_schema.mbt model.mbt
```

Arguments: `[--check] OUTPUT INPUT [INPUT ...]`. Supply all annotated types
from one package in a fixed order. Existing output is replaced only if line 1
has this tool's generated-file marker; user-owned files are refused. Writes
replace the complete file, and `--check` compares bytes without writing.
There is no deletion command. The header records generator and compiler
versions, so a toolchain bump regenerates the files in the same change.

## Generation and compilation

Use a `moon.pkg` rule so `moon check`, `moon build` and `moon test` generate
the file and then compile it as part of the consumer package. Compilation is
required: attributes describe syntax, while only the compiler can check the
types of custom codecs and defaults. A successful generator exit alone is
not a compilation check.

```moonbit nocheck
rule(
  name: "schema",
  command: "moonx gaato/mttp_schemagen@0.1.0 $output $input",
)
dev_build(rule: "schema", input: "model.mbt", output: "model_schema.mbt")
```

For an unpublished local checkout, substitute this command (paths must be
absolute because `-C` changes the tool's working directory):

```moonbit nocheck
command: "moon -C /absolute/path/to/mttp_schemagen run src --target wasm -- \"$mod_dir/$output\" \"$mod_dir/$input\""
```

The generator itself stays outside the repository's `moon.work` to isolate
parser's runtime dependencies. `scripts/modules.tsv` registers its `tool`
kind for independent tests, packaging and release tags.

## Types and attributes

```moonbit nocheck
///|
#mttp.schema
struct Note {
  /// A title of at most 20 characters.
  #mttp.codec(title_codec)
  title : String
  #mttp.nullable
  rating : Int32?
}
```

Doc comments become descriptions; `#mttp.schema(name="WireName")` changes
the schema component name. Public types produce public `<snake_case>_codec`
values. Validators are ordinary hand-written codecs selected by `codec(...)`.

| Syntax | Codec |
|---|---|
| Int / Int32, Int64, Double, Bool, String, Json | jint, jint64, jdouble, jbool, jstring, jvalue |
| Array[T], Map[String,T] | array, map_of |
| T? | option: absent/null both None; None is omitted in objects |
| `#mttp.omittable` on T? | omittable: absent is None; null goes to the child codec |
| `#mttp.nullable` on T? | nullable: key required, null is None, None encodes as null |
| @jsonkit.Presence[T] | presence: absent and null stay distinct |
| Annotated same-package U | u_codec |

Field attributes are `rename("wire")`, `codec(value)`, `omittable`,
`nullable`, repeatable `example("<JSON text>")`, and
`schema_default(identifier)`. `omittable` and `nullable` are mutually exclusive.
`codec(...)` replaces the child codec inside `T?` / Presence wrappers;
otherwise it replaces the whole value codec. Examples and schema defaults
only document values: a required field remains required. The prototype's
`#mttp.default` spelling is refused with a migration message because it could
be mistaken for a default applied during decoding.

MoonBit source identifiers must be valid MoonBit names. Escape reserved JSON
names deterministically with an underscore and `rename`, for example
`#mttp.rename("true")` on `true_`, `"false"` on `false_`, `"None"` on `none_`,
and `"Json"` on `json_`. Wire names always remain quoted strings. Constructor
arguments use indexed bindings and explicit field assignments, so fields
named `value`, `self_codec` or `mttp_field_0` do not capture generated locals.
The integration test generates, compiles and runs this fixture from scratch.

Argument-less enums use `string_enum(...).map(...)`; `#mttp.tag("wire")`
overrides each case's wire string. Tagged enums require one unlabeled,
annotated same-package struct per known case:

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

The default discriminator is `type`, and the default wire tag is the case
name. One optional `#mttp.unknown` case may carry exactly one Json. It retains
the entire unknown tagged object and re-encodes it unchanged. It accepts only
unknown string tags; invalid known payloads, missing/non-string discriminators
and non-objects still fail. The schema includes an unknown-tag alternative
without changing known discriminator mappings. `Unknown` is intended for
values obtained from decoding: constructing it manually with a known tag
violates the fallback encoder's precondition. The generated code uses
`tagged(unknown=...)`, so both paths preserve the caller's decode budget.

Self-recursive structs use `recursive`. Unsupported declarations/attributes,
generics, tuple/empty structs, more than 16 fields, mixed enums, duplicate wire
names/tags and malformed examples are hard errors with file:line:column.
Enums have 1 to 64 cases. The tool does not raise object16's limit.

`schema_default` is refused on any field whose generated codec encodes
through its type's recursive proxy, including inside arrays/maps/options or
Presence. Defaults encode their value while constructing the codec, before
that proxy is initialized; the generator cannot inspect an identifier's
value to prove it empty or None. Defaults on nonrecursive fields remain
supported, as do explicit codec overrides that do not use the generated
proxy. Use a hand-written codec for a recursive default annotation.
Distinct types must also have distinct generated codec names: for example,
`FooBar` and `Foo_bar` both map to `foo_bar_codec` and are refused together.

## Repository checks and releases

```sh
moon -C mttp_schemagen test --target wasm --deny-warn
moon run scripts/check_schemagen.mbtx
moon run scripts/check_schemagen.mbtx -- --update
```

On the pinned toolchain, the static gate byte-checks all committed fixtures.
After changing the compiler or generator version, regenerate and review the
goldens in that same change; this detects formatting and emission drift.
Update both `moon.mod` and the compiled `tool_version` when changing the tool
version; a test checks that they agree.

The module has its own CHANGELOG and the `mttp_schemagen-v*` release trigger.
Publish the required core release first, and allow the tool's tag pattern in
the GitHub `mooncakes` environment before tagging. Publishing and tagging are
separate release actions; no publication happens while generating code.

The adoption trial removed 42 hand-written shortlinks lines, added 10
attribute lines and 9 wrapper/adapter lines, saving 23 lines (54.8%).

## License

[Apache-2.0](https://github.com/gaato/mttp/blob/main/LICENSE).
