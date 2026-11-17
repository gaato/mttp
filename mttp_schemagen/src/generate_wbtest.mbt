///|
async test "Note source matches the golden bytes" {
  let input = @fs.read_text("note.input")
  let golden = @fs.read_text("note.golden")
  let toolchain = toolchain_version()
  let actual = formatted(generate([("note.input", input)], toolchain~))
  assert_true(golden.has_prefix("\{generated_marker} v\{tool_version}; moonc "))
  if golden.has_prefix(
      "\{generated_marker} v\{tool_version}; moonc \{toolchain}. ",
    ) {
    assert_eq(actual, golden)
  }
  assert_eq(
    generate([("note.input", input)]),
    generate([("note.input", input)]),
  )
}

///|
fn refuses(source : String, expected : String) -> Unit raise {
  let message = try {
    ignore(generate([("bad.mbt", source)]))
    "accepted"
  } catch {
    Invalid(message) => message
  }
  assert_true(message.has_prefix("bad.mbt:"))
  assert_true(message.contains(expected), msg=message)
}

///|
test "recursive field defaults are refused before proxy initialization" {
  let source =
    #|#mttp.schema
    #|struct DefaultTree {
    #|  value : Int
    #|  #mttp.schema_default(default_children)
    #|  children : Array[DefaultTree]
    #|}
    #|let default_children : Array[DefaultTree] = [{ value: 1, children: [] }]
  refuses(source, "schema_default cannot encode a recursive field")
  for
    ty in [
      "DefaultTree?", "Map[String, DefaultTree]", "@jsonkit.Presence[DefaultTree]",
    ] {
    refuses(
      "#mttp.schema\nstruct DefaultTree {\n#mttp.schema_default(default_value)\nchild : \{ty}\n}",
      "schema_default cannot encode a recursive field",
    )
  }
}

///|
test "recursive codecs retain defaults that do not encode through the proxy" {
  let source =
    #|#mttp.schema
    #|struct SafeTree {
    #|  children : Array[SafeTree]
    #|  #mttp.schema_default(default_count)
    #|  count : Int
    #|  #mttp.codec(external_child)
    #|  #mttp.schema_default(default_child)
    #|  child : SafeTree?
    #|}
  let output = generate([("safe.mbt", source)])
  assert_true(output.contains("@schema.recursive("))
  assert_true(output.contains("@schema.jint.with_default(default_count)"))
  assert_true(
    output.contains(
      "@schema.option((external_child)).with_default(default_child)",
    ),
  )
}

///|
test "derived codec names are unique across input files" {
  let message = try {
    ignore(
      generate([
        ("first.mbt", "#mttp.schema\nstruct FooBar { value : Int }"),
        ("second.mbt", "#mttp.schema\nstruct Foo_bar { value : String }"),
      ]),
    )
    "accepted"
  } catch {
    Invalid(message) => message
  }
  assert_true(message.has_prefix("second.mbt:"), msg=message)
  assert_true(message.contains("foo_bar_codec"), msg=message)
  assert_true(
    message.contains("FooBar") && message.contains("Foo_bar"),
    msg=message,
  )
}

///|
test "reviewed discriminator and constructor attribute refusals remain positioned" {
  for value_type in ["String", "Int"] {
    for
      (tag, annotation) in [
        ("type", ""),
        ("kind", "#mttp.discriminator(\"kind\")\n"),
      ] {
      refuses(
        "#mttp.schema\nstruct Payload {\n#mttp.rename(\"\{tag}\")\nvalue : \{value_type}\n}\n#mttp.schema\n\{annotation}enum Event { A(Payload) }",
        "payload field collides with discriminator \{tag}",
      )
    }
  }
  for argument in ["", "(Payload)"] {
    let payload = "#mttp.schema\nstruct Payload { value : Int }\n"
    refuses(
      payload +
      "#mttp.schema\nenum Event {\n#mttp.unrecognized\nA\{argument}\n}",
      "unsupported #mttp.unrecognized",
    )
    refuses(
      payload +
      "#mttp.schema\nenum Event {\n#mttp.tag(\"a\")\n#mttp.tag(\"a\")\nA\{argument}\n}",
      "duplicate #mttp.tag",
    )
  }
}

///|
test "positioned refusals cover unsupported declarations and attributes" {
  refuses("#mttp.schema\nstruct Box[T] { item : T }", "generic")
  refuses("#mttp.schema\nstruct Pair(Int, String)", "tuple structs")
  let fields = Array::makei(17, i => "f\{i} : Int").join("\n")
  refuses("#mttp.schema\nstruct Wide {\n\{fields}\n}", "1 to 16")
  refuses("#mttp.schema\nstruct Empty {}", "1 to 16")
  refuses("#mttp.schema\nstruct Unknown { x : Other }", "unknown type")
  refuses(
    "#mttp.schema\nstruct Wrong {\n#mttp.omittable\nx : Int\n}", "requires T?",
  )
  refuses(
    "#mttp.schema\nstruct Wrong {\n#mttp.example(\"oops\")\nx : Int\n}", "valid JSON",
  )
  refuses(
    "#mttp.schema\nstruct Wrong {\n#mttp.schema_default(1)\nx : Int\n}", "identifier",
  )
  refuses(
    "#mttp.schema\nstruct Wrong {\n#mttp.unknown\nx : Int\n}", "unsupported #mttp",
  )
  refuses("#mttp.schema\n#mttp.schema\nstruct Wrong { x : Int }", "duplicate")
  refuses("#mttp.schema\nenum Wrong { A(Int) }", "one annotated")
  let cases = Array::makei(65, i => "C\{i}").join("\n")
  refuses("#mttp.schema\nenum Wide {\n\{cases}\n}", "1 to 64")
  refuses("#mttp.schema\nstruct Broken { x : }", "Unexpected")
  refuses(
    "#mttp.schema\nstruct Legacy {\n#mttp.default(count)\nx : Int\n}", "schema_default",
  )
  refuses(
    "struct Unmarked {\n#mttp.nullable\nx : Int?\n}", "require #mttp.schema",
  )
  refuses("#mttp.schema\nlet ignored = 1", "unsupported on this declaration")
  refuses(
    "#mttp.schema\nstruct Both {\n#mttp.omittable\n#mttp.nullable\nx : Int?\n}",
    "mutually exclusive",
  )
  refuses(
    "#mttp.schema\n#mttp.discriminator(\"kind\")\nstruct Bad { x : Int }", "only supported on enums",
  )
  refuses(
    "#mttp.schema\nenum Bad {\n#mttp.codec(codec)\nA\n}", "unsupported #mttp",
  )
  refuses(
    "#mttp.schema\nenum Bad {\n#mttp.unknown\nA(String)\n}", "unlabeled Json",
  )
  refuses(
    "#mttp.schema\nenum Bad {\n#mttp.tag(\"a\")\nA\n#mttp.tag(\"a\")\nB\n}", "duplicate wire tag",
  )
  refuses(
    "#mttp.schema\nstruct A { b : B? }\n#mttp.schema\nstruct B { a : A? }", "mutual recursion",
  )
  refuses(
    "#mttp.schema\nstruct A { x : Int }\nlet a_codec = 1", "binding a_codec already exists",
  )
}

///|
test "enum case bound accepts exactly sixty four" {
  let cases = Array::makei(64, i => "C\{i}").join("\n")
  let output = generate([
    ("cases.mbt", "#mttp.schema\nenum Wide {\n\{cases}\n}"),
  ])
  assert_true(output.contains("Wide::C63"))
}

///|
async test "generated version matches the module release version" {
  let manifest = @fs.read_text("moon.mod")
  assert_true(manifest.contains("version = \"\{tool_version}\""))
}

///|
async fn test_directory() -> String {
  let result = @shell.Cmd("mktemp", [
    "-d", "/var/tmp/mttp-schemagen-test.XXXXXXXX",
  ]).output()
  result.check()
  result.stdout().trim().to_owned()
}

///|
/// `rm -rf`, like `mktemp` above: `@fs.rmdir` is deprecated on newer
/// toolchains, and `@fs.remove` is not recursive on the pinned 0.10.20.
async fn remove_test_directory(dir : String) -> Unit {
  @shell.Cmd("rm", ["-rf", "--", dir]).output().check()
}

///|
async test "only marked files are replaced and check never writes" {
  let dir = test_directory()
  defer @async.protect_from_cancel(() => remove_test_directory(dir))
  let path = dir + "/model_schema.mbt"
  @fs.write_text(path, "// user code\nlet sentinel = 1\n")
  let marked = generated_marker + " v0.1.0; moonc test. Do not edit.\n"
  assert_true(
    try {
      write_output(path, marked, check=false)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(@fs.read_text(path), "// user code\nlet sentinel = 1\n")
  let generated = dir + "/generated.mbt"
  write_output(generated, marked, check=false)
  write_output(generated, marked, check=true)
  assert_true(
    try {
      write_output(generated, marked + "// stale\n", check=true)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(@fs.read_text(generated), marked)
  write_output(generated, marked + "// updated\n", check=false)
  assert_eq(@fs.read_text(generated), marked + "// updated\n")
  @fs.write_text(generated + ".schemagen-new", "// user sidecar\n")
  assert_true(
    try {
      write_output(generated, marked, check=false)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(@fs.read_text(generated + ".schemagen-new"), "// user sidecar\n")
  @fs.write_text(generated + ".schemagen-new", marked)
  write_output(generated, marked, check=false)
  assert_eq(@fs.read_text(generated), marked)
  let missing = dir + "/missing.mbt"
  assert_true(
    try {
      write_output(missing, marked, check=true)
      false
    } catch {
      _ => true
    },
  )
  assert_false(@fs.exists(missing))
}

///|
async test "freshly generated collision and response fixtures compile and execute" {
  let dir = test_directory()
  defer @async.protect_from_cancel(() => remove_test_directory(dir))
  let source = @fs.read_text("release.input") +
    "\n" +
    (
      #|///|
      #|let self_codec : @schema.JsonCodec[Int] = @schema.jint
      #|///|
      #|#derive(Eq, Debug)
      #|#mttp.schema
      #|struct BinderTree {
      #|  #mttp.codec(self_codec)
      #|  value : Int
      #|  children : Array[BinderTree]
      #|}
      #|///|
      #|test "recursive binder preserves a user codec named self_codec" {
      #|  let value = BinderTree::{ value: 1, children: [{ value: 2, children: [] }] }
      #|  assert_eq(binder_tree_codec.from_json(binder_tree_codec.to_json(value)), value)
      #|}
    )
  let output = formatted(
    generate([("release.input", source)], toolchain=toolchain_version()),
  )
  @fs.write_text(dir + "/model_test.mbt", source)
  write_output(dir + "/model_schema_test.mbt", output, check=false)
  let local_core = @fs.realpath("../mttp_core") catch { _ => "" }
  let version = if local_core == "" {
    "0.2.1"
  } else {
    // The coordinated core release will bump this version; the local
    // compiler fixture must follow its manifest rather than pinning 0.2.0.
    let manifest = @fs.read_text(local_core + "/moon.mod")
    manifest
    .split("\n")
    .filter_map(line => {
      match line.strip_prefix("version = \"") {
        Some(rest) => rest.strip_suffix("\"").map(value => value.to_owned())
        None => None
      }
    })
    .to_array()[0]
  }
  @fs.write_text(
    dir + "/moon.mod",
    "name = \"schemagen/fixture\"\nimport { \"gaato/mttp_core@\{version}\" }\n",
  )
  @fs.write_text(
    dir + "/moon.pkg",
    "import { \"gaato/mttp_core/schema\" } for \"test\"\n",
  )
  if local_core != "" {
    @fs.write_text(
      dir + "/moon.work",
      "members = [\".\", \{quoted(local_core)}]\n",
    )
  }
  let result = @shell.Cmd("moon", [
    "-C", dir, "test", "-p", "schemagen/fixture", "--target", "wasm", "--deny-warn",
  ]).output(timeout_ms=60000)
  assert_eq(result.exit_code(), 0, msg=result.stdout() + result.stderr())
  assert_true(result.stdout().contains("Total tests: 3, passed: 3, failed: 0."))
}

///|
test "all type mappings metadata and sixteen fields produce checked syntax" {
  let source =
    #|/// A record.
    #|#mttp.schema(name="Wire")
    #|struct Shapes {
    #|  a : Int
    #|  b : Int64
    #|  c : Double
    #|  d : Bool
    #|  e : String
    #|  f : Json
    #|  g : Array[String]
    #|  h : Map[String, Int]
    #|  i : String?
    #|  j : @jsonkit.Presence[String]
    #|  #mttp.omittable
    #|  k : String?
    #|  #mttp.rename("wire")
    #|  #mttp.example("1")
    #|  #mttp.example("2")
    #|  #mttp.schema_default(default_value)
    #|  l : Int
    #|  #mttp.codec(@schema.jstring.validate(@schema.max_length(20)))
    #|  m : String
    #|  n : Shapes?
    #|  o : Array[Shapes]
    #|  p : Map[String, Shapes]
    #|}
  let output = generate([("shapes.mbt", source)])
  for
    expected in [
      "object16", "jint64", "jdouble", "jbool", "jvalue", "array(", "map_of(", "option(",
      "presence(", "omittable(", "with_examples([1, 2])", "with_default(default_value)",
      "with_description(\"A record.\")", "recursive(", "\"Wire\"",
    ] {
    assert_true(output.contains(expected), msg=expected)
  }
  let (_, reports) = @parser.parse_string(output)
  assert_eq(reports.length(), 0)
}
