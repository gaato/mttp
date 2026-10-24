///|
fn compiles(p : String) -> String {
  let _ = @string.Regex(p) catch { e => return "ERR(\{e})" }
  "ok"
}

///|
fn matches(p : String, s : String) -> String {
  let r = @string.Regex(p) catch { e => return "ERR(\{e})" }
  match r.execute(s) {
    Some(m) => "match(\{m.content()})"
    None => "none"
  }
}

///|
test "ecma-262 patterns from real OpenAPI specs" {
  // anthropic.json / github / openrouter patterns, verbatim
  inspect(compiles("^[a-zA-Z0-9_-]{1,64}$"), content=(
    #|ERR(ParserError at position 12: Dash at the start or end of character class is not supported, use \- to match a literal dash)
  ))
  inspect(compiles("^\\d{4}-\\d{2}-\\d{2}$"), content=(
    #|ERR(ParserError at position 1: Use POSIX character class instead of \w, \W, \d, \D, \s, \S)
  ))
  inspect(compiles("^[\\w-]+$"), content=(
    #|ERR(ParserError at position 2: Use POSIX character class instead of \w, \W, \d, \D, \s, \S)
  ))
  inspect(compiles("^[a-zA-Z0-9._-]+$"), content=(
    #|ERR(ParserError at position 13: Dash at the start or end of character class is not supported, use \- to match a literal dash)
  ))
}

///|
test "search vs anchored semantics (JSON Schema pattern is unanchored search)" {
  // ECMA: /abc/.test("xxabcxx") == true
  inspect(matches("abc", "xxabcxx"), content=(
    #|match(abc)
  ))
  // a POSIX class means something else in ECMA-262
  inspect(matches("[[:digit:]]+", "a12b"), content=(
    #|match(12)
  ))
}
