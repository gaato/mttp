///|
// Example Objects remain in unmodeled: adding fields to the released
// pub(all) MediaTypeObject would break callers constructing records.
fn add_examples(
  content : Map[String, @apispec.MediaTypeObject],
  examples : Array[(String, Json, String?)],
) -> Unit {
  if examples.is_empty() {
    return
  }
  for name, media in content.copy() {
    let values = match media.unmodeled.get("examples") {
      Some(Object(values)) => values.copy()
      _ => Map([])
    }
    for (key, value, summary) in examples {
      let example = { "value": value }
      if summary is Some(summary) {
        example["summary"] = Json(summary)
      }
      values[key] = Json::object(example)
    }
    let unmodeled = media.unmodeled.copy()
    unmodeled["examples"] = Json::object(values)
    content[name] = { ..media, unmodeled, }
  }
}
