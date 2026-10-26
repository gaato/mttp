///|
test "typed Endpoint Router and H1 engines exchange through SimNet" {
  for chunk_bytes in [1, 17, 65536] {
    let driver = @driver.Driver::new()
    let coordination = @sim.SimCoordination::new(driver)
    let clock = @fake.SimClock::new(driver)
    let timer = @fake.SimTimer::new(driver)
    let (client_conn, server_conn) = @sim.pair(coordination, chunk_bytes~)
    let route = @endpoint.endpoint
      .get("/items/{id}")
      .input(@endpoint.path("id", @schema.int))
      .output(@endpoint.text_out())
    let router = @router.Router::new([
      route.serve_public(id => Ok(id.to_string())),
    ])
    let backend = @http.H1Backend::new(
      dialer=@sim.ScriptedDialer::new([client_conn]),
      clock~,
      timer~,
      coordination~,
    )
    driver.run(() => {
      let server = driver.spawn(() => {
        @server.serve_conn(
          server_conn,
          request => router.dispatch(request),
          clock~,
          timer~,
          coordination~,
        )
      })
      let reply = backend.send(
        @model.Request::get("http://localhost/items/42"),
        @httpclient.RequestOptions::default(),
      )
      assert_eq(reply.status, 200)
      assert_eq(@httpclient.read_body(reply.body, 20), b"42")
      backend.close()
      ignore(server.wait())
    })
    assert_eq(client_conn.closes(), 1)
    assert_eq(server_conn.closes(), 1)
  }
}
