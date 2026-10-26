///|
test "headers normalize names and preserve pair order and multiple values" {
  let input = [("X-A", "one"), ("X-B", "two"), ("x-a", "three")]
  let mut headers = @model.Headers::of(input)
  input.clear()
  assert_eq(headers.length(), 3)
  assert_eq(headers.get("X-A"), Some("one"))
  assert_true(headers.contains("x-B"))
  assert_eq(headers.get("missing"), None)
  assert_eq(headers.get_all("missing"), [])
  assert_eq(headers.get_all("X-a"), ["one", "three"])
  let values = headers.get_all("x-a")
  values.clear()
  assert_eq(headers.get_all("x-a"), ["one", "three"])
  let expected = [("x-a", "one"), ("x-b", "two"), ("x-a", "three")]
  assert_eq(headers.iter().to_array(), expected)
  let visited = []
  headers.each((name, value) => visited.push((name, value)))
  assert_eq(visited, expected)
  assert_eq(headers, @model.Headers::of(expected))
  assert_true(headers != @model.Headers::of([("X-A", "one")]))
  headers = headers.add("X-B", "four")
  assert_eq(headers.iter().to_array(), [..expected, ("x-b", "four")])
}

///|
test "set replaces all values in place and remove removes all values" {
  let mut headers = @model.Headers::of([
    ("A", "1"),
    ("B", "2"),
    ("a", "3"),
    ("C", "4"),
  ])
  headers = headers.set("a", "replacement")
  assert_eq(headers.iter().to_array(), [
    ("a", "replacement"),
    ("b", "2"),
    ("c", "4"),
  ])
  headers = headers.set("D", "5")
  headers = headers.add("B", "6")
  headers = headers.remove("b")
  headers = headers.remove("missing")
  assert_true(!headers.contains("B"))
  assert_eq(headers.iter().to_array(), [
    ("a", "replacement"),
    ("c", "4"),
    ("d", "5"),
  ])
  let mut empty = @model.Headers::empty()
  assert_eq(empty.length(), 0)
  empty = empty.remove("absent")
  empty = empty.set("NEW", "value")
  assert_eq(empty.get("new"), Some("value"))
}
