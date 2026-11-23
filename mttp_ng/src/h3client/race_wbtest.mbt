// The race of two addresses for a QUIC handshake (`H3Backend::race`),
// driven with IPv4 addresses so that it runs on hosts without an IPv6
// loopback too (the gate image has none): a server of h3server on one, and
// on the other a socket that takes Initials and never answers, or a port
// nothing listens on.

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
/// Runs `run` with an HTTP/3 server on 127.0.0.1 and its address.
async fn with_h3_server(run : async (@socket.Addr) -> Unit) -> Unit {
  let quic = @h3.ServerQuic::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
  @async.with_timeout(20000, () => {
    @async.with_task_group(group => {
      let bound : Ref[String?] = Ref(None)
      let listening = @cond_var.Cond()
      group.spawn_bg(() => {
        @h3server.serve(
          _ => @mttp_core.Response::new(200),
          addr="127.0.0.1:0",
          quic~,
          on_listen=addr => {
            bound.val = Some(addr)
            listening.broadcast()
          },
        )
      })
      while bound.val is None {
        listening.wait()
      }
      run(@socket.Addr::parse(bound.val.unwrap()))
      group.return_immediately()
    })
  })
}

///|
/// The race between `first` and `other` for the server's origin: what won,
/// and how long it took.
async fn race_of(
  server : @socket.Addr,
  first : @socket.Addr,
  other : @socket.Addr,
) -> (Bool, Int64) {
  let b = H3Backend::new(trust=PemFile(testdata("root.pem")))
  defer b.close()
  let text = server.to_string()
  let port = text[text.rev_find(":").unwrap() + 1:].to_owned()
  let target = @mux.target(
    @mttp_core.Request::get("https://localhost:\{port}/"),
  )
  let started = b.clock.now_unix_ms()
  let won = b.race(b.quic.unwrap(), target, first, other)
  let took = b.clock.now_unix_ms() - started
  if won is Some(connection) {
    connection.close()
  }
  (won is Some(_), took)
}

///|
async test "a silent first address loses the race to the other, before the budget" {
  with_h3_server(server => {
    let silent = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer silent.close()
    let (won, took) = race_of(server, silent.addr, server)
    assert_true(won)
    assert_true(took < HANDSHAKE_MS.to_int64(), msg="took \{took} ms")
  })
}

///|
async test "a first address that refuses at once starts the other without the delay" {
  with_h3_server(server => {
    // A port nothing listens on: the kernel answers with ICMP.
    let closed = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
    let refused = closed.addr
    closed.close()
    let (won, took) = race_of(server, refused, server)
    assert_true(won)
    assert_true(took < HANDSHAKE_MS.to_int64(), msg="took \{took} ms")
  })
}

///|
async test "the first address wins when it answers" {
  with_h3_server(server => {
    let silent = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer silent.close()
    let (won, took) = race_of(server, server, silent.addr)
    assert_true(won)
    assert_true(took < FAMILY_DELAY_MS.to_int64() * 4, msg="took \{took} ms")
  })
}

///|
async test "two silent addresses lose within the handshake budget" {
  with_h3_server(server => {
    let a = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer a.close()
    let c = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer c.close()
    let (won, took) = race_of(server, a.addr, c.addr)
    assert_false(won)
    assert_true(took < HANDSHAKE_MS.to_int64() * 2, msg="took \{took} ms")
  })
}
