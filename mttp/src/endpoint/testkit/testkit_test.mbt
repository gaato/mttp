///|
suberror Missing {
  Missing(Int32)
}

///|
test "typed stub decodes requests and raises declared errors on the client" {
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
  let errors = @endpoint.Errors::new(
    error => {
      match error {
        Missing(_) as missing => Some(missing)
        _ => None
      }
    },
    [error_variant],
  )
  let ep = @endpoint.endpoint
    .get("/items/{id}")
    .input(@endpoint.path("id", @schema.int))
    .output(@endpoint.text_out())
    .errors(errors)
  let stub = @testing.BackendStub::new()
  ignore(
    @testkit.when_endpoint(stub, ep, id => {
      if id == 9 {
        raise Missing(id)
      } else {
        "item " + id.to_string()
      }
    }),
  )
  let client = @client.Client::new(stub, @fake.FakeClock::new())
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), 2), "item 2")
    let result = try {
      ignore(ep.call(client, (), 9))
      None
    } catch {
      Missing(id) => Some(id)
      _ => None
    }
    assert_eq(result, Some(9))
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
  ignore(@testkit.when_endpoint(stub, exact, _ => ()))
  let rest = @endpoint.endpoint
    .get("/prefix/files/{tail...}")
    .input(@endpoint.paths("tail"))
  ignore(@testkit.when_endpoint(stub, rest, _ => ()))
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
