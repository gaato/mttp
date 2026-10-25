///|
test "stream variant projections retain decoding and event ownership" {
  let variant = sse_out(@schema.jint).variants[0].contramap(
    (value : EventStream[Int32]) => Some(value),
    value => value,
  )
  let driver = @driver.Driver::new()
  driver.run(() => {
    let source = @feed.Feed::bytes(driver, [b"data: 4\n\n"])
    let decode = variant.decode_stream.unwrap()
    let stream = decode(@model.Response::new(200).head(), source)
    let values = []
    stream.each(value => values.push(value))
    assert_eq(values, [4])
    assert_eq(source.closes(), 1)
  })
}

///|
test "internal stream adapters obey the shared BodyStream contract" {
  let driver = @driver.Driver::new()
  driver.run(() => {
    assert_eq(
      @testing.check_body_stream_contract(
        () => BufferedStream::new(b"abc"),
        b"abc",
      ),
      [],
    )
    assert_eq(
      @testing.check_body_stream_contract(
        () => ResponseOwner::{
          reader: @feed.Feed::bytes(driver, [b"a", b"bc"]),
          request: Empty,
          closed: false,
        },
        b"abc",
      ),
      [],
    )
    assert_eq(
      @testing.check_body_stream_contract(
        () => LimitedInput::{
          reader: @feed.Feed::bytes(driver, [b"a", b"bc"]),
          limit: 3,
          count: 0L,
          failure: Ref(None),
          closed: false,
        },
        b"abc",
      ),
      [],
    )
    assert_eq(
      @testing.check_body_stream_contract(
        () => {
          let source = @feed.Feed::bytes(driver, [b"a", b"bc"])
          EventBody::{
            pull: () => source.read_some(),
            close_: () => source.close(),
            done: false,
          }
        },
        b"abc",
      ),
      [],
    )
  })
}
