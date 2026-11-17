///|
#derive(Eq, Debug)
#mttp.schema
enum Mood {
  Quiet
  Bright
}

///|
/// An envelope of notes.
#mttp.schema(name="NoteEnvelope")
struct Envelope {
  #mttp.rename("items")
  notes : Array[ShapeNote]
  mood : Mood
  counts : Map[String, Int32]
  #mttp.codec(title_codec)
  #mttp.omittable
  label : String?
  #mttp.example("1")
  #mttp.example("2")
  #mttp.schema_default(default_count)
  count : Int32
}

///|
let default_count : Int32 = 2

///|
#mttp.schema
enum Selection {
  Single(ShapeNote)
  Many(Envelope)
}

///|
#derive(Eq, Debug)
#mttp.schema
struct ShapeNote {
  #mttp.codec(title_codec)
  title : String
  stars : Int32
}

///|
#derive(Eq, Debug)
#mttp.schema
struct Tree {
  value : Int32
  children : Array[Tree]
}

///|
test "generated enum containers annotations and recursive struct run as ordinary codecs" {
  assert_eq(mood_codec.from_json("Quiet"), Quiet)
  assert_eq(mood_codec.to_json(Bright), "Bright")
  let input : Json = {
    "items": [{ "title": "hello", "stars": 2 }],
    "mood": "Bright",
    "counts": { "hello": 2 },
    "count": 1,
  }
  let envelope = envelope_codec.from_json(input)
  assert_eq(envelope.label, None)
  assert_eq(envelope_codec.to_json(envelope), input)
  let selected = selection_codec.to_json(Many(envelope))
  assert_eq(
    selection_codec.to_json(selection_codec.from_json(selected)),
    selected,
  )
  let single = Single(ShapeNote::{ title: "hello", stars: 3, })
  assert_eq(
    selection_codec.to_json(
      selection_codec.from_json(selection_codec.to_json(single)),
    ),
    selection_codec.to_json(single),
  )
  let tree = Tree::{ value: 1, children: [{ value: 2, children: [], }], }
  assert_eq(tree_codec.from_json(tree_codec.to_json(tree)), tree)
  assert_true(
    try {
      ignore(
        envelope_codec.from_json({
          "items": [],
          "mood": "Bright",
          "counts": {},
          "count": 1,
          "label": null,
        }),
      )
      false
    } catch {
      _ => true
    },
  )
  // A documented default never makes a required field optional.
  assert_true(
    try {
      ignore(
        envelope_codec.from_json({ "items": [], "mood": "Bright", "counts": {} }),
      )
      false
    } catch {
      _ => true
    },
  )
}
