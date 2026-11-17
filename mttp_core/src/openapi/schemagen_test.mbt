///|
#derive(Eq, Debug)
#mttp.schema
struct Note {
  /// The note title, at most 20 characters.
  #mttp.codec(title_codec)
  title : String
  stars : Int32
}

///|
let title_codec : @schema.JsonCodec[String] = @schema.jstring.validate(
  @schema.max_length(20),
)

///|
let handwritten_note : @schema.JsonCodec[Note] = @schema.object2(
  "Note",
  @schema.field(
    "title",
    title_codec,
    (note : Note) => note.title,
    description="The note title, at most 20 characters.",
  ),
  @schema.field("stars", @schema.jint, (note : Note) => note.stars),
  (title, stars) => { title, stars, },
)

///|
test "generated Note equals handwritten schema OpenAPI issues and round trips" {
  assert_eq(note_codec.schema(), handwritten_note.schema())
  let hand = @endpoint.endpoint
    .post("/notes")
    .input(@endpoint.body(handwritten_note.body()))
    .output(@endpoint.json_out(handwritten_note.body()))
  let generated = @endpoint.endpoint
    .post("/notes")
    .input(@endpoint.body(note_codec.body()))
    .output(@endpoint.json_out(note_codec.body()))
  let info = @apispec.Info::new("Notes", "1")
  assert_eq(
    Json(@openapi.to_openapi([generated.doc()], info)),
    Json(@openapi.to_openapi([hand.doc()], info)),
  )
  let inputs : Array[Json] = [
    {},
    { "stars": 1 },
    { "title": "ok" },
    { "title": 3, "stars": false },
    { "title": "123456789012345678901", "stars": 1 },
    { "title": "ok", "stars": 1, "extra": true },
    { "title": "ok", "stars": 1 },
    null,
  ]
  for input in inputs {
    let expected = Ok(handwritten_note.from_json(input)) catch {
      @schema.DecodeFailure(kind=Invalid(issues), ..) => Err(issues)
      other => fail("unexpected handwritten failure: \{other}")
    }
    let actual = Ok(note_codec.from_json(input)) catch {
      @schema.DecodeFailure(kind=Invalid(issues), ..) => Err(issues)
      other => fail("unexpected generated failure: \{other}")
    }
    assert_eq(actual, expected)
  }
  for
    value in [
      Note::{ title: "", stars: 0, },
      { title: "12345678901234567890", stars: 42, },
    ] {
    assert_eq(note_codec.to_json(value), handwritten_note.to_json(value))
    assert_eq(note_codec.from_json(handwritten_note.to_json(value)), value)
    assert_eq(handwritten_note.from_json(note_codec.to_json(value)), value)
  }
}
