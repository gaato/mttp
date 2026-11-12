// Local servers for the tests, none of them this module's code: mttp_async's
// HTTP/1.1 server, an HTTP/2 server over TLS on moonhttp's state machine and
// moontls, and bare TCP listeners that misbehave on purpose. Everything binds
// 127.0.0.1 on a free port, so the tests need no network.

///|
/// Runs `run` with mttp_async's server answering `handler` at the address it
/// passes, bounded so a hang fails the test instead of the suite.
async fn with_h1_server(
  handler : async (@mttp.Request) -> @mttp.Response noraise,
  run : async (String) -> Unit,
) -> Unit {
  @async.with_timeout(20000, () => {
    @async.with_task_group(group => {
      let ready : Ref[String?] = Ref(None)
      let wake = @cond_var.Cond()
      group.spawn_bg(no_wait=true, () => {
        @server.serve(handler, addr="127.0.0.1:0", on_listen=address => {
          ready.val = Some(address)
          wake.signal()
        })
      })
      while ready.val is None {
        wake.wait()
      }
      run(ready.val.unwrap())
      group.return_immediately()
    })
  })
}

///|
/// What the HTTP/2 test server does with a request.
priv enum H2Answer {
  /// Answers with the status, fields and body.
  Reply(Int32, Array[(String, String)], Bytes)
  /// Resets the stream with REFUSED_STREAM without answering.
  Refuse
  /// Sends the head with this status and never ends the stream.
  Hold(Int32)
}

///|
/// The moontls settings that trust the test root.
fn trusting() -> @tls.Client raise {
  @tls.Client::new(@x509.Roots::pem(test_root))
}

///|
/// Runs `run` with an HTTP/2 server over TLS (ALPN `h2` only) on the test
/// certificate, answering each request with `answer(method, path, fields,
/// body)`. `run` receives the port and the number of connections that
/// carried a request so far. `max_streams` is the server's
/// SETTINGS_MAX_CONCURRENT_STREAMS, and `ended` counts the connections that
/// carried a request and have closed.
async fn with_h2_server(
  answer : (String, String, Array[(String, String)], Bytes) -> H2Answer,
  run : async (Int32, Ref[Int32]) -> Unit,
  max_streams? : Int32,
  ended~ : Ref[Int32] = Ref(0),
) -> Unit {
  let tls = @tls.Server::new(
    @x509.pems(test_cert),
    @x509.PrivateKey::pem(test_key),
    alpn=["h2"],
  )
  let connections = Ref(0)
  @async.with_timeout(20000, () => {
    @async.with_task_group(group => {
      let listener = @tcp.listen(host="127.0.0.1", port=0, tls~)
      group.spawn_bg(no_wait=true, () => {
        listener.serve((conn, _) => {
          serve_h2(conn, answer, connections, ended, max_streams?) catch {
            _ => ()
          }
          conn.close()
        })
      })
      run(listener.addr().port(), connections)
      listener.close()
      group.return_immediately()
    })
  })
}

///|
async fn serve_h2(
  conn : @tcp.Conn,
  answer : (String, String, Array[(String, String)], Bytes) -> H2Answer,
  connections : Ref[Int32],
  ended : Ref[Int32],
  max_streams? : Int32,
) -> Unit {
  let wire = @http2.Conn::new(
    Server,
    settings=@http2.Settings::new(max_concurrent_streams=max_streams),
  )
  let open : Map[Int32, (Array[(String, String)], Buffer)] = Map([])
  let mut counted = false
  defer (if counted { ended.val += 1 })
  for ;; {
    let out = wire.take()
    if out.length() > 0 {
      conn.write(out)
    }
    match wire.next() {
      NeedData => {
        guard conn.read_some(max_len=16384) is Some(data) else { return }
        wire.receive(data[:])
      }
      Request(stream~, fields~) => {
        if !counted {
          counted = true
          connections.val += 1
        }
        open[stream] = (fields.map(f => f.ascii()), Buffer())
      }
      Data(stream~, data~) => {
        if open.get(stream) is Some((_, buffer)) {
          buffer.write_bytes(data)
        }
        wire.acknowledge(stream, data.length())
      }
      End(stream~) => {
        guard open.get(stream) is Some((fields, buffer)) else { continue }
        open.remove(stream)
        let field = (name : String) => {
          fields.iter().find_first(f => f.0 == name).map(f => f.1).unwrap_or("")
        }
        match
          answer(field(":method"), field(":path"), fields, buffer.to_bytes()) {
          Refuse => wire.reset(stream, code=7)
          Hold(status) =>
            wire.headers(
              stream,
              [@header.Header::of(":status", status.to_string())],
              end=false,
            )
          Reply(status, extra, body) => {
            let head = [@header.Header::of(":status", status.to_string())]
            for f in extra {
              head.push(@header.Header::of(f.0, f.1))
            }
            wire.headers(stream, head, end=body.is_empty())
            if !body.is_empty() {
              wire.data(stream, body[:], end=true)
            }
          }
        }
      }
      Closed | GoAway(..) => return
      _ => ()
    }
  }
}

///|
/// Runs `run` with a bare TCP listener whose connections `serve` handles.
async fn with_tcp_server(
  serve : async (@tcp.Conn) -> Unit,
  run : async (Int32) -> Unit,
) -> Unit {
  @async.with_timeout(20000, () => {
    @async.with_task_group(group => {
      let listener = @tcp.listen(host="127.0.0.1", port=0)
      group.spawn_bg(no_wait=true, () => {
        listener.serve((conn, _) => {
          serve(conn) catch {
            _ => ()
          }
          conn.close()
        })
      })
      run(listener.addr().port())
      listener.close()
      group.return_immediately()
    })
  })
}

///|
/// Reads until the end of an HTTP/1.1 request head.
async fn read_head(conn : @tcp.Conn) -> Unit {
  ignore(conn.read_until("\r\n\r\n"))
}

///|
/// A port nothing listens on: one a listener held and gave up.
async fn closed_port() -> Int32 {
  let listener = @tcp.listen(host="127.0.0.1", port=0)
  let port = listener.addr().port()
  listener.close()
  port
}
