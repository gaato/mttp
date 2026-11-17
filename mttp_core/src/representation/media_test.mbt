///|
fn accept(value : String) -> @mttp_core.Headers {
  @mttp_core.Headers::of([("accept", value)])
}

///|
test "RFC Accept examples quality specificity wildcards parameters and exclusions" {
  for
    (value, offers, expected) in [
      (
        "audio/*; q=0.2, audio/basic",
        ["audio/wave", "audio/basic"],
        @representation.Offer(1),
      ),
      (
        "text/plain; q=0.5, text/html, text/x-dvi; q=0.8, text/x-c",
        ["text/plain", "text/x-dvi", "text/html"],
        Offer(2),
      ),
      (
        "text/*, text/plain, text/plain;format=flowed, */*",
        ["text/html", "text/plain", "text/plain;format=flowed"],
        Offer(2),
      ),
      (
        "text/*;q=0.3, text/html;q=0.7, text/html;level=1, text/html;level=2;q=0.4, */*;q=0.5",
        ["image/jpeg", "text/html;level=2", "text/html;level=1"],
        Offer(2),
      ),
      ("text/plain;q=0, */*;q=1", ["text/plain", "application/json"], Offer(1)),
      ("text/plain;q=0, */*;q=1", ["text/plain"], Unacceptable),
      (
        "text/plain;q=0.5, application/json;q=0.5",
        ["application/json", "text/plain"],
        Offer(0),
      ),
      (
        "text/plain;q=0.5, application/json;q=0.8",
        ["text/plain", "application/json"],
        Offer(1),
      ),
      ("TEXT/PLAIN;CHARSET=\"UTF-8\"", ["text/plain;charset=utf-8"], Offer(0)),
      (
        "text/plain;profile=\"a,b;c\"",
        ["text/plain;profile=\"a,b;c\""],
        Offer(0),
      ),
      (
        "text/plain;profile=\"a\\\"b\"",
        ["text/plain;profile=\"a\\\"b\""],
        Offer(0),
      ),
      ("", ["text/plain"], Unacceptable),
    ] {
    assert_eq(
      @representation.negotiate_media(accept(value), offers[:]),
      expected,
      msg=value,
    )
  }
  assert_eq(
    @representation.negotiate_media(@mttp_core.Headers::empty(), [
      "text/plain", "text/html",
    ]),
    @representation.Offer(0),
  )
  assert_eq(
    @representation.negotiate_media(@mttp_core.Headers::empty(), []),
    @representation.Unacceptable,
  )
  assert_eq(
    @representation.negotiate_media(
      @mttp_core.Headers::of([
        ("Accept", "text/plain;q=0.1"),
        ("Accept", "text/html"),
      ]),
      ["text/plain", "text/html"],
    ),
    @representation.Offer(1),
  )
}

///|
test "Accept bounds reject 16 KiB plus one and 129 items and malformed weights" {
  for n in [16384, 16385] {
    let field = "text/plain" + String::make(n - 10, ' ')
    try @representation.negotiate_media(accept(field), ["text/plain"]) catch {
      @mttp_core.TransportError(kind=Invalid, phase=Head, ..) =>
        assert_eq(n, 16385)
      error => raise error
    } noraise {
      result => {
        assert_eq(n, 16384)
        assert_eq(result, @representation.Offer(0))
      }
    }
  }
  for n in [128, 129] {
    let field = Array::make(n, "text/plain").join(",")
    try @representation.negotiate_media(accept(field), ["text/plain"]) catch {
      @mttp_core.TransportError(kind=Invalid, phase=Head, ..) =>
        assert_eq(n, 129)
      error => raise error
    } noraise {
      result => {
        assert_eq(n, 128)
        assert_eq(result, @representation.Offer(0))
      }
    }
  }
  for
    field in [
      "text/plain;q=1.001", "text/plain;q=0.1234", "text/plain;q=-1", "text/plain;q=x",
      "text/plain;q=2", "text/plain;q=", "text/plain;q=1;q=0", "*/plain", "plain",
      "text/plain;p=\"unterminated", "text/plain;p=bad value", "text/plain;p",
    ] {
    try
      ignore(@representation.negotiate_media(accept(field), ["text/plain"]))
    catch {
      @mttp_core.TransportError(kind=Invalid, phase=Head, ..) => ()
      error => raise error
    } noraise {
      _ => fail("accepted malformed Accept: " + field)
    }
  }
  let unicode = "text/plain;p=\"" + String::make(8192, 'é') + "\""
  try
    ignore(@representation.negotiate_media(accept(unicode), ["text/plain"]))
  catch {
    @mttp_core.TransportError(kind=Invalid, phase=Head, ..) => ()
    error => raise error
  } noraise {
    _ => fail("UTF-8 byte limit was ignored")
  }
}
