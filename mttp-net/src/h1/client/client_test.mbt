///|
test "portable engine exchanges fragmented bytes without a runtime" {
  for chunk_bytes in [1, 17, 65536] {
    let driver = @driver.Driver::new()
    let coordination = @sim.SimCoordination::new(driver)
    let (client_conn, peer) = @sim.pair(coordination, chunk_bytes~)
    let dialer = @sim.ScriptedDialer::new([client_conn])
    let backend = @client.H1Backend::new(
      dialer~,
      coordination~,
      clock=@fake.SimClock::new(driver),
      timer=@fake.SimTimer::new(driver),
    )
    driver.run(() => {
      let remote = driver.spawn(() => {
        let decoder = @h1.HeadDecoder::new()
        for ;; {
          guard peer.read(max_len=65536) is Some(bytes) else { break }
          if decoder.feed(bytes).head is Some(_) {
            peer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nbody")
            break
          }
        }
      })
      let response = backend.send(
        @model.Request::get("http://example.test/"),
        @httpclient.RequestOptions::default(),
      )
      assert_eq(@httpclient.read_body(response.body, 10), b"body")
      assert_eq(backend.idle_connections(), 1)
      backend.close()
      ignore(remote.wait())
      peer.close()
    })
    assert_eq(client_conn.closes(), 1)
    assert_eq(dialer.dialed(), [("example.test", 80)])
  }
}
