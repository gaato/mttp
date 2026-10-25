///|
test "encoding negotiation honors weights exclusions aliases and identity" {
  assert_eq(
    @codings.negotiate_encoding(@model.Headers::empty()),
    @codings.Identity,
  )
  for
    (value, choice) in [
      ("", @codings.Identity),
      ("gzip", @codings.Encoded(Gzip)),
      ("gzip;q=0.2, br;q=0.8", @codings.Encoded(Brotli)),
      ("gzip;q=0, *;q=0.5", @codings.Encoded(Deflate)),
      ("gzip;q=0.4, identity;q=0.5", @codings.Identity),
      ("*;q=0", @codings.Unacceptable),
      ("zstd, identity;q=0", @codings.Unacceptable),
      ("*;q=0, identity;q=0.1", @codings.Identity),
      ("GZIP;q=0, x-gzip;q=1", @codings.Identity),
      ("br;q=1.000, deflate;q=1.", @codings.Encoded(Deflate)),
      ("gzip;q=0.", @codings.Identity),
    ] {
    assert_eq(
      @codings.negotiate_encoding(
        @model.Headers::of([("Accept-Encoding", value)]),
      ),
      choice,
    )
  }
  assert_eq(
    @codings.negotiate_encoding(
      @model.Headers::of([
        ("Accept-Encoding", "gzip"),
        ("accept-encoding", "gzip;q=0, br"),
      ]),
    ),
    @codings.Encoded(Brotli),
  )
}

///|
test "encoding negotiation rejects malformed weights and bounds field bytes and entries" {
  let non_ascii = try {
    ignore(
      @codings.negotiate_encoding(
        @model.Headers::of([("accept-encoding", String::make(8193, 'é'))]),
      ),
    )
    false
  } catch {
    @model.TransportError(kind=Invalid, ..) => true
    _ => false
  }
  assert_true(non_ascii)
  for
    value in [
      "gzip;q=",
      "gzip;q=2",
      "gzip;q=1.001",
      "gzip;q=0.1234",
      "gzip;q=.5",
      "gzip;q=0.a",
      "gzip;q=00",
      "gzip;p=1",
      "gzip;q=1;x=2",
      Array::make(129, "gzip").join(","),
      "gzip" + String::make(16381, ' '),
    ] {
    let rejected = try {
      ignore(
        @codings.negotiate_encoding(
          @model.Headers::of([("accept-encoding", value)]),
        ),
      )
      false
    } catch {
      @model.TransportError(kind=Invalid, phase=Head, ..) => true
      _ => false
    }
    assert_true(rejected)
  }
  assert_eq(
    @codings.negotiate_encoding(
      @model.Headers::of([
        ("accept-encoding", Array::make(128, "gzip").join(",")),
      ]),
    ),
    @codings.Encoded(Gzip),
  )
  assert_eq(
    @codings.negotiate_encoding(
      @model.Headers::of([
        ("accept-encoding", "gzip" + String::make(16380, ' ')),
      ]),
    ),
    @codings.Encoded(Gzip),
  )
}
