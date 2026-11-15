///|
fn ws_error_detail(f : () -> Unit raise) -> String {
  try f() catch {
    @ws.WsError(detail~, ..) => detail
    error => "unexpected: \{@debug.to_string(error)}"
  } noraise {
    _ => "no error"
  }
}

///|
fn repeated(value : String, count : Int32, separator~ : String = "") -> String {
  let parts = []
  for _ in 0..<count {
    parts.push(value)
  }
  parts.join(separator)
}

///|
test "extension grammar parses tokens quotes escapes and prints canonically" {
  let parsed = @handshake.parse_extensions(
    " permessage-deflate ; client_max_window_bits = 15 ; flag, x-test; note=\"a b\\\"c\\\\d\" ",
  )
  let expected : Array[@handshake.Extension] = [
    {
      name: "permessage-deflate",
      params: [
        { name: "client_max_window_bits", value: Some("15"), },
        { name: "flag", value: None, },
      ],
    },
    { name: "x-test", params: [{ name: "note", value: Some("a b\"c\\d"), }], },
  ]
  assert_eq(parsed, expected)
  assert_eq(
    @handshake.print_extensions(parsed),
    "permessage-deflate; client_max_window_bits=15; flag, x-test; note=\"a b\\\"c\\\\d\"",
  )
  assert_eq(
    @handshake.parse_extensions(@handshake.print_extensions(parsed)),
    parsed,
  )
}

///|
test "extension malformed corpus is refused" {
  for
    value in [
      "", " ", ",x", "x,", "x,,y", ";a", "x;", "x; =v", "x;a=", "x;a=\"unterminated",
      "x;a=\"trailing\\", "x;a=\"escaped\\\r\"", "x;a=\"escaped\\\u0000\"", "x;a=\"escaped\\\u001f\"",
      "x;a=\"escaped\\\u007f\"", "x;a=\"bad\rvalue\"", "x a", "x;a=v junk",
    ] {
    assert_true(
      ws_error_detail(() => ignore(@handshake.parse_extensions(value))) !=
      "no error",
    )
  }
  assert_true(
    ws_error_detail(() => {
      ignore(
        @handshake.print_extensions([
          ({ name: "bad name", params: [], } : @handshake.Extension),
        ]),
      )
    }) !=
    "no error",
  )
  assert_true(
    ws_error_detail(() => ignore(@handshake.print_extensions([]))).contains(
      "empty extension",
    ),
  )
  let too_many : Array[@handshake.Extension] = []
  for _ in 0..<33 {
    too_many.push({ name: "x", params: [], })
  }
  assert_true(
    ws_error_detail(() => ignore(@handshake.print_extensions(too_many))).contains(
      "32 elements",
    ),
  )
  let too_many_params : Array[@handshake.ExtensionParam] = []
  for _ in 0..<33 {
    too_many_params.push({ name: "a", value: None, })
  }
  assert_true(
    ws_error_detail(() => {
      ignore(
        @handshake.print_extensions([{ name: "x", params: too_many_params, }]),
      )
    }).contains("32 parameters"),
  )
  assert_true(
    ws_error_detail(() => {
      ignore(
        @handshake.print_extensions([
          { name: "x", params: [{ name: "bad name", value: None, }], },
        ]),
      )
    }).contains("parameter name"),
  )
  assert_true(
    ws_error_detail(() => {
      ignore(
        @handshake.print_extensions([
          { name: "x", params: [{ name: "a", value: Some("bad\rvalue"), }], },
        ]),
      )
    }).contains("parameter value"),
  )
  assert_true(
    ws_error_detail(() => {
      ignore(
        @handshake.print_extensions([
          { name: repeated("a", 16385), params: [], },
        ]),
      )
    }).contains("16384"),
  )
}

///|
test "extension header bounds admit exact values and refuse bound plus one" {
  let exact_bytes = repeated("a", 16384)
  assert_eq(@handshake.parse_extensions(exact_bytes)[0].name.length(), 16384)
  assert_true(
    ws_error_detail(() => ignore(@handshake.parse_extensions(exact_bytes + "a"))).contains(
      "16384",
    ),
  )
  let exact_extensions = repeated("x", 32, separator=",")
  assert_eq(@handshake.parse_extensions(exact_extensions).length(), 32)
  assert_true(
    ws_error_detail(() => {
      ignore(@handshake.parse_extensions(exact_extensions + ",x"))
    }).contains("32 elements"),
  )
  let exact_params = "x;" + repeated("a", 32, separator=";")
  assert_eq(@handshake.parse_extensions(exact_params)[0].params.length(), 32)
  assert_true(
    ws_error_detail(() => {
      ignore(@handshake.parse_extensions(exact_params + ";a"))
    }).contains("32 parameters"),
  )
}

///|
test "extension quoted escapes admit HTAB SP VCHAR and obs-text" {
  let parsed = @handshake.parse_extensions("x; a=\"\\\t\\ \\!\\\u0080\"")
  assert_eq(parsed[0].params[0].value, Some("\t !\u0080"))
}

///|
test "extension printer enforces the projected quoted length" {
  let exact_value = repeated(" ", 16375) + "\\"
  let exact = @handshake.print_extensions([
    { name: "x", params: [{ name: "a", value: Some(exact_value), }], },
  ])
  assert_eq(exact.length(), 16384)
  assert_true(
    ws_error_detail(() => {
      ignore(
        @handshake.print_extensions([
          {
            name: "x",
            params: [{ name: "a", value: Some(" " + exact_value), }],
          },
        ]),
      )
    }).contains("16384"),
  )
}
