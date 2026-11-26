// The bound RESOURCE_BOUNDS.md gives a TLS session: it holds at most one
// record of ciphertext that a read took from beneath, however much the
// peer sent ahead of the reader.

///|
#borrow(session)
extern "C" fn input_held(session : Session) -> Int32 = "mttp_ng_tls_input_held"

///|
async fn testdata(name : String) -> String {
  for dir in ["../../testdata", "testdata", "mttp_ng/testdata"] {
    if @fs.exists("\{dir}/\{name}") {
      return @fs.realpath("\{dir}/\{name}")
    }
  }
  fail("no testdata/\{name} below the working directory")
}

///|
async test "a read takes one record from beneath, however much is sent ahead" {
  @async.with_timeout(10000, () => {
    let server_tls = ServerTls::from_pem(
      chain=@fs.read_text(testdata("localhost.pem")),
      key=@fs.read_text(testdata("localhost.key")),
      alpn=["h2"],
    )
    let client_tls = ClientTls::new(trust=PemFile(testdata("root.pem")), alpn=[
      "h2",
    ])
    let coordination = @runtime.RuntimeCoordination::new()
    let (left, right) = @sim.pair(coordination)
    let accepted : Ref[TlsConn?] = Ref(None)
    let connected : Ref[TlsConn?] = Ref(None)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        accepted.val = Some(server_tls.accept(right, coordination~))
      })
      connected.val = Some(
        client_tls.connect(left, host="localhost", coordination~),
      )
    })
    let client = connected.val.unwrap()
    let server = accepted.val.unwrap()
    defer client.close()
    defer server.close()
    // A megabyte in one write: about 64 full records wait beneath the
    // client before it reads any (a SimConn write never blocks).
    let total = 1 << 20
    server.write(Bytes::makei(total, i => (i % 251).to_byte()))
    let mut received = 0
    let mut most = 0
    while received < total {
      guard client.read(max_len=1000) is Some(chunk) else {
        fail("EOF after \{received} bytes")
      }
      received += chunk.length()
      let held = input_held(client.session)
      if held > most {
        most = held
      }
    }
    assert_true(most > 0, msg="nothing was ever held: the probe saw nothing")
    assert_true(most <= RECORD_BYTES, msg="held \{most} bytes of ciphertext")
  })
}
