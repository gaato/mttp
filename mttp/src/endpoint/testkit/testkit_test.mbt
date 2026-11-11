///|
#derive(Debug, Eq)
enum Missing {
  Missing(Int32)
}

///|
test "verify reports adapter ceiling advisories and schema union problems" {
  let doc = @endpoint.endpoint.post("/").max_body_bytes(9).doc()
  let problems = @testkit.verify([doc], adapter_max_body_bytes=8)
  assert_eq(problems.length(), 1)
  assert_false(problems[0].fatal)
  let case_ = @schema.case_("same", @schema.jint, (n : Int32) => Some(n), n => n)
  let ep = @endpoint.endpoint
    .get("/")
    .output(
      @endpoint.json_out(@schema.any_of("Duplicate", [case_, case_]).body()),
    )
  assert_true(@testkit.verify([ep.doc()]).iter().any(p => p.fatal))
}

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
  let driver = @driver.Driver::new()
  let clock = @sim.SimClock::new(driver)
  let timer = @sim.SimTimer::new(driver)
  ignore(
    @testkit.when_endpoint(
      stub,
      ep,
      id => {
        if id == 9 {
          Err(Missing(id))
        } else {
          Ok("item " + id.to_string())
        }
      },
      clock~,
      timer~,
    ),
  )
  let client = @client.Client::new(stub, clock, timeout_ms=100)
  driver.run(() => {
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
        @mttp.Request::post("/exact/id"),
        @mttp.Request::get("http://["),
        @mttp.Request::get("/exact"),
        @mttp.Request::get("/other/id"),
        @mttp.Request::get("/prefix"),
      ] {
      let failed = try {
        ignore(stub.send(request, @mttp.SendOptions::default()))
        false
      } catch {
        @mttp.TransportError(kind=Protocol, ..) => true
        _ => false
      }
      assert_true(failed)
    }
    assert_eq(
      stub.send(
        @mttp.Request::get("/prefix/files/a/b"),
        @mttp.SendOptions::default(),
      ).status,
      200,
    )
  })
  stub.close()
}
