///|
test "stream variant projections retain decoding and event ownership" {
  let variant = sse_out(@schema.jint).variants[0].contramap(
    (value : EventStream[Int32]) => Some(value),
    value => value,
  )
  let driver = @driver.Driver::new()
  driver.run(() => {
    let source = @sim.Feed::bytes(driver, [b"data: 4\n\n"])
    let decode = variant.decode_stream.unwrap()
    let stream = decode(@mttp_core.Response::new(200).head(), source)
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
    @sim.check_body_stream_contract(() => BufferedStream::new(b"abc"), b"abc")
    @sim.check_body_stream_contract(
      () => ResponseOwner::{
        reader: @sim.Feed::bytes(driver, [b"a", b"bc"]),
        request: Empty,
        closed: false,
        ended: false,
      },
      b"abc",
    )
    @sim.check_body_stream_contract(
      () => LimitedInput::{
        reader: @sim.Feed::bytes(driver, [b"a", b"bc"]),
        limit: 3,
        count: 0L,
        failure: Ref(None),
        closed: false,
        ended: false,
      },
      b"abc",
    )
    // Over a source with trailers, each passes them on at its own end.
    let trailers = @mttp_core.Headers::of([("x-checksum", "9")])
    let trailed = () => {
      guard @mttp_core.Body::with_trailers(b"abc", trailers~) is Stream(cell) else {
        abort("not a stream")
      }
      cell.take() catch {
        _ => abort("taken")
      }
    }
    @sim.check_body_stream_contract(
      () => ResponseOwner::{
        reader: trailed(),
        request: Empty,
        closed: false,
        ended: false,
      },
      b"abc",
      trailers~,
    )
    @sim.check_body_stream_contract(
      () => LimitedInput::{
        reader: trailed(),
        limit: 3,
        count: 0L,
        failure: Ref(None),
        closed: false,
        ended: false,
      },
      b"abc",
      trailers~,
    )
    @sim.check_body_stream_contract(
      () => {
        let source = @sim.Feed::bytes(driver, [b"a", b"bc"])
        EventBody::{
          events: EventStream::from_pull(() => source.read_some(), () => {
            source.close()
          }),
          encode: bytes => bytes,
          opened: false,
          done: false,
        }
      },
      b":\n\nabc",
    )
  })
}
