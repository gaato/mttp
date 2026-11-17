///|
fn head(
  fields : Array[(String, String)],
  meth~ : @mttp_core.Method = Get,
) -> @mttp_core.RequestHead {
  let request = @mttp_core.Request::new(meth, "/")
  { ..request, headers: @mttp_core.Headers::of(fields), }.head()
}

///|
test "preconditions follow RFC order for every presence combination" {
  let validators = @representation.Validators::new(
    etag="\"v1\"",
    last_modified_ms=100000L,
  )
  // Each condition would stop processing if reached; If-Match wins over
  // If-Unmodified-Since, and If-None-Match wins over If-Modified-Since.
  for mask in 0..<16 {
    let fields = []
    if mask.land(1) != 0 {
      fields.push(("if-match", "\"v1\""))
    }
    if mask.land(2) != 0 {
      fields.push(("if-unmodified-since", @mttp_core.format_http_date(0L)))
    }
    if mask.land(4) != 0 {
      fields.push(("if-none-match", "\"other\""))
    }
    if mask.land(8) != 0 {
      fields.push(("if-modified-since", @mttp_core.format_http_date(100000L)))
    }
    let expected : @representation.Precondition = if mask.land(1) == 0 &&
      mask.land(2) != 0 {
      Failed
    } else if mask.land(4) == 0 && mask.land(8) != 0 {
      NotModified
    } else {
      Proceed
    }
    assert_eq(
      @representation.evaluate_preconditions(head(fields), validators),
      expected,
    )
  }
  for mask in 0..<16 {
    let fields = []
    if mask.land(1) != 0 {
      fields.push(("if-match", "\"other\""))
    }
    if mask.land(2) != 0 {
      fields.push(("if-unmodified-since", @mttp_core.format_http_date(0L)))
    }
    if mask.land(4) != 0 {
      fields.push(("if-none-match", "W/\"v1\""))
    }
    if mask.land(8) != 0 {
      fields.push(("if-modified-since", @mttp_core.format_http_date(100000L)))
    }
    let expected : @representation.Precondition = if mask.land(3) != 0 {
      Failed
    } else if mask.land(12) != 0 {
      NotModified
    } else {
      Proceed
    }
    assert_eq(
      @representation.evaluate_preconditions(head(fields), validators),
      expected,
    )
  }
  assert_eq(
    @representation.evaluate_preconditions(
      head([
        ("if-match", "\"v1\""),
        ("if-unmodified-since", @mttp_core.format_http_date(0L)),
      ]),
      validators,
    ),
    @representation.Proceed,
  )
  assert_eq(
    @representation.evaluate_preconditions(
      head([
        ("if-none-match", "\"other\""),
        ("if-modified-since", @mttp_core.format_http_date(100000L)),
      ]),
      validators,
    ),
    @representation.Proceed,
  )
}

///|
test "strong If-Match weak If-None-Match wildcard methods and date precision" {
  let validators = @representation.Validators::new(
    etag="\"a,b\"",
    last_modified_ms=100999L,
  )
  for
    (fields, meth, expected) in [
      ([("if-match", "W/\"a,b\"")], @mttp_core.Get, @representation.Failed),
      ([("if-match", "\"other\", \"a,b\"")], Get, Proceed),
      ([("if-none-match", "W/\"a,b\"")], Get, NotModified),
      ([("if-none-match", "\"a,b\"")], Head, NotModified),
      ([("if-none-match", "*")], Post, Failed),
      ([("if-match", "*")], Put, Proceed),
      (
        [("if-modified-since", @mttp_core.format_http_date(100000L))],
        Get,
        NotModified,
      ),
      (
        [("if-modified-since", @mttp_core.format_http_date(100000L))],
        Post,
        Proceed,
      ),
      (
        [("if-unmodified-since", @mttp_core.format_http_date(100000L))],
        Put,
        Proceed,
      ),
      ([("if-modified-since", "invalid")], Get, Proceed),
      ([("if-unmodified-since", "invalid")], Get, Proceed),
      ([("if-match", "unquoted")], Get, Failed),
      ([("if-match", "\"other\"x")], Get, Failed),
      ([("if-match", "\"unclosed")], Get, Failed),
      ([("if-match", "W/")], Get, Failed),
    ] {
    assert_eq(
      @representation.evaluate_preconditions(head(fields, meth~), validators),
      expected,
    )
  }
  let weak = @representation.Validators::new(etag="W/\"a,b\"")
  let absent = @representation.Validators::new()
  assert_eq(
    @representation.evaluate_preconditions(
      head([("if-match", "\"v1\"")]),
      absent,
    ),
    @representation.Failed,
  )
  assert_eq(
    @representation.not_modified(absent, @mttp_core.Headers::empty()).status,
    304,
  )
  let before_epoch = @representation.Validators::new(last_modified_ms=-1L)
  assert_eq(
    @representation.evaluate_preconditions(
      head([("if-modified-since", @mttp_core.format_http_date(-1000L))]),
      before_epoch,
    ),
    @representation.NotModified,
  )
  assert_eq(
    @representation.evaluate_preconditions(
      head([("if-match", "\"a,b\"")]),
      weak,
    ),
    @representation.Failed,
  )
  assert_eq(
    @representation.evaluate_preconditions(
      head([("if-none-match", "\"a,b\"")]),
      weak,
    ),
    @representation.NotModified,
  )
  assert_eq(
    @representation.evaluate_preconditions(
      head([("if-match", "*")]),
      @representation.Validators::new(),
    ),
    @representation.Proceed,
  )
  let response = @representation.not_modified(
    validators,
    @mttp_core.Headers::of([
      ("vary", "Accept"),
      ("cache-control", "max-age=60"),
      ("content-length", "12"),
    ]),
  )
  assert_eq(response.status, 304)
  assert_eq(response.body, @mttp_core.Empty)
  assert_eq(response.headers.get("etag"), Some("\"a,b\""))
  assert_eq(response.headers.get("vary"), Some("Accept"))
  assert_eq(response.headers.get("content-length"), None)
}

///|
test "malformed matching entity tag items and lists never satisfy conditions" {
  let validators = @representation.Validators::new(etag="\"v1\"")
  for
    field in [
      "\"v1\"garbage", "\"v1\" garbage", "\"v1\" \"v2\"", "\"v1\", garbage", "\"v1\", \"unclosed",
      "\"v1\", *", "\"v1\", \"has space\"", "\"v1\", \"\u{7f}\"", "\"v1\", \"\u{100}\"",
    ] {
    assert_eq(
      @representation.evaluate_preconditions(
        head([("if-match", field)]),
        validators,
      ),
      @representation.Failed,
      msg=field,
    )
    for meth in [@mttp_core.Get, Head, Post] {
      assert_eq(
        @representation.evaluate_preconditions(
          head([("if-none-match", field)], meth~),
          validators,
        ),
        @representation.Proceed,
        msg=field,
      )
    }
  }
  for name in ["if-match", "if-none-match"] {
    assert_eq(
      @representation.evaluate_preconditions(
        head([(name, "\"v1\""), (name, "garbage")]),
        validators,
      ),
      if name == "if-match" {
        @representation.Failed
      } else {
        @representation.Proceed
      },
    )
  }
  assert_eq(
    @representation.evaluate_preconditions(
      head([("if-match", ",, \"v2\", \"v1\", ,")]),
      validators,
    ),
    @representation.Proceed,
  )
  assert_eq(
    @representation.evaluate_preconditions(
      head([("if-match", "\"v1\" , \"v2\"")]),
      validators,
    ),
    @representation.Proceed,
  )
}
