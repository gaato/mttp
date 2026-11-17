///|
async test "Note source matches the golden bytes" {
  let input = @fs.read_text("note.input")
  let golden = @fs.read_text("note.golden")
  assert_eq(formatted(generate([("note.input", input)])), golden)
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
    "#mttp.schema\nstruct Wrong {\n#mttp.default(1)\nx : Int\n}", "identifier",
  )
  refuses(
    "#mttp.schema\nstruct Wrong {\n#mttp.unknown\nx : Int\n}", "unsupported #mttp",
  )
  refuses("#mttp.schema\n#mttp.schema\nstruct Wrong { x : Int }", "duplicate")
  refuses("#mttp.schema\nenum Wrong { A(Int) }", "one annotated")
  let cases = Array::makei(65, i => "C\{i}").join("\n")
  refuses("#mttp.schema\nenum Wide {\n\{cases}\n}", "1 to 64")
  refuses("#mttp.schema\nstruct Broken { x : }", "Unexpected")
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
    #|  #mttp.default(default_value)
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
