///|
enum Missing {
  Missing(Int32)
} derive(Debug, Eq)

///|
test "typed stub decodes requests and returns declared error values on the client" {
  let error_variant : @endpoint.Variant[Missing] = @endpoint.json_variant(
    404,
    @schema.jint.body(),
  ).contramap(
    error => {
      let Missing(id) = error
      Some(id)
    },
    id => Missing(id),
  )
  let errors = @endpoint.one_of([error_variant])
  let ep = @endpoint.endpoint
    .get("/items/{id}")
    .input(@endpoint.path("id", @schema.int))
    .output(@endpoint.text_out())
    .errors(errors)
  let stub = @testing.BackendStub::new()
  ignore(
    @testkit.when_endpoint(stub, ep, id => {
      if id == 9 {
        Err(Missing(id))
      } else {
        Ok("item " + id.to_string())
      }
    }),
  )
  let client = @client.Client::new(stub, @fake.FakeClock::new())
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), 2).unwrap().unwrap(), "item 2")
    let result = ep.call(client, (), 9)
    assert_true(result is Ok(Err(Missing(9))))
  })
  assert_eq(stub.sent().length(), 2)
  assert_eq(@testkit.verify([ep.doc()]), [])
  assert_true(!@testkit.verify([@endpoint.endpoint.doc()]).is_empty())
  client.close()
}

///|
test "endpoint stub matching rejects wrong methods paths and malformed URLs" {
  let stub = @testing.BackendStub::new()
  let exact = @endpoint.endpoint
    .get("/exact/{id}")
    .input(@endpoint.path("id", @schema.string))
  ignore(@testkit.when_endpoint(stub, exact, _ => Ok(())))
  let rest = @endpoint.endpoint
    .get("/prefix/files/{tail...}")
    .input(@endpoint.paths("tail"))
  ignore(@testkit.when_endpoint(stub, rest, _ => Ok(())))
  @driver.run_sync(() => {
    for
      request in [
        @model.Request::post("/exact/id"),
        @model.Request::get("http://["),
        @model.Request::get("/exact"),
        @model.Request::get("/other/id"),
        @model.Request::get("/prefix"),
      ] {
      let failed = try {
        ignore(stub.send(request, @client.RequestOptions::default()))
        false
      } catch {
        @model.TransportError(kind=Protocol, ..) => true
        _ => false
      }
      assert_true(failed)
    }
    assert_eq(
      stub.send(
        @model.Request::get("/prefix/files/a/b"),
        @client.RequestOptions::default(),
      ).status,
      200,
    )
  })
  stub.close()
}
