///|
test "ECMA pattern translation preserves character classes anchors and whitespace" {
  let cases : Array[(String, Array[String], Array[String])] = [
    (
      "^[a-zA-Z0-9_-]{1,64}$",
      ["a_A-09", "x".repeat(64)],
      ["", "x".repeat(65), "a\n", "é"],
    ),
    ("^\\d+$", ["123"], ["x", "１２"]),
    ("^[\\w]+$", ["ab_19"], ["é", "-"]),
    ("^\\s$", [" ", "\t", "\n", "\u00a0", "\u2028", "\ufeff"], ["a", "\u0085"]),
    ("^\\D$", ["a"], ["3"]),
    ("^\\W$", ["é"], ["_"]),
    ("^\\S$", ["a"], ["\u3000"]),
    ("^.$", ["a", "😀"], ["\n", "\r", "\u2028", "\u2029", "ab"]),
    ("(?:cat|dog)", ["a cat!", "dog"], ["cow"]),
    ("^[-a]+$", ["-a"], ["b"]),
    ("^[^-a]+$", ["b"], ["-"]),
    ("^a{2,}$", ["aa", "aaa"], ["a"]),
    ("^a?b*c+$", ["cc", "abcc"], ["a"]),
    ("^\\.$", ["."], ["a"]),
  ]
  for (source, yes, no) in cases {
    let codec = @schema.string.validate(@schema.pattern(source))
    for value in yes {
      assert_eq(codec.decode(value), value, msg=source)
    }
    for value in no {
      rejects(() => codec.decode(value))
    }
    assert_eq(property(codec.schema().json, "pattern"), Some(Json(source)))
  }
}

///|
test "pattern translator refuses unsupported syntax and compilation growth" {
  for
    source in [
      "a".repeat(1025),
      "\\",
      "\\p{L}",
      "\\1",
      "\\x61",
      "[\\D]",
      "[\\d-a]",
      "[a-\\d]",
      "[[:digit:]]",
      "[]",
      "[^]",
      "(?=a)",
      "(?i:a)",
      "(a)+",
      "a{257}",
      "a{1x}",
      "a{1",
      "[",
      "(",
      ")(",
      "*a",
      "(".repeat(33) + "a" + ")".repeat(33),
      "a{256}".repeat(17),
    ] {
    try {
      let _ = @schema.pattern(source)
      fail("unsupported pattern accepted: " + source)
    } catch {
      @schema.UnsupportedPattern(_) => ()
      error => raise error
    }
  }
  for
    source in [
      "a".repeat(1024),
      "(".repeat(32) + "a" + ")".repeat(32),
      "a{256}".repeat(16),
    ] {
    try {
      let _ = @schema.pattern(source)
    } catch {
      @schema.UnsupportedPattern(reason) =>
        fail("boundary refused: " + source + ": " + reason)
    }
  }
}
