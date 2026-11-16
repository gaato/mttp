///|
#cfg(not(target="js"))
let limits : @core_ws.WsLimits = {
  ..@core_ws.WsLimits::default(),
  max_frame_bytes: 64 << 20,
  max_message_bytes: 64 << 20,
  // Section 9 includes bursts of empty and tiny fragments. Memory remains
  // bounded by the message ceiling, while this explicit work bound is raised.
  max_empty_frames: 1000000,
  ping_interval_ms: None,
  pong_timeout_ms: None,
}

///|
#cfg(not(target="js"))
async fn open(base : String, path : String) -> &@core_ws.Session {
  let backend = @backend.AsyncBackend::new(
    config=@h1client.ClientConfig::default(),
  )
  defer backend.close()
  @ws.connect(base + path, limits~, backend~)
}

///|
#cfg(not(target="js"))
async fn control(base : String, path : String) -> String {
  let session = open(base, path)
  defer session.abort()
  let result = session.recv() catch {
    @core_ws.WsError(kind=Closed(_), ..) => return ""
    error => raise error
  }
  session.close({ code: Normal, reason: "", })
  match result {
    Text(text) => text
    Binary(_) => ""
  }
}

///|
#cfg(not(target="js"))
async fn main {
  let args = @env.args()
  let base = args.get(1).unwrap_or("ws://127.0.0.1:39050")
  let count = @string.parse_int(control(base, "/getCaseCount"))
  println("Autobahn: \{count} cases")
  for case in 1..<=count {
    @async.with_timeout(180000, () => {
      let session = open(base, "/runCase?case=\{case}&agent=mttp-client")
      defer session.abort()
      for ;; {
        let message = session.recv() catch { _ => break }
        session.send(message) catch {
          _ => break
        }
      }
    })
    println("Autobahn case \{case}/\{count} completed")
  }
  ignore(control(base, "/updateReports?agent=mttp-client"))
}

///|
#cfg(target="js")
async fn main {
  @async.with_timeout(10000, () => {
    let args = @env.args()
    let url = args.get(args.length() - 1).unwrap_or("ws://127.0.0.1:39507/")
    let session = @ws.connect(url, subprotocols=["other", "echo"])
    defer session.abort()
    assert_eq(session.subprotocol(), Some("echo"))
    if url.has_suffix("?shutdown") {
      assert_eq(session.recv(), Text("ready"))
    }
    session.send(Text("héllo 🌙"))
    assert_eq(session.recv(), Text("héllo 🌙"))
    session.send(Binary(b"\x00\x80\xff"))
    assert_eq(session.recv(), Binary(b"\x00\x80\xff"))
    session.close({ code: Other(4001), reason: "finished", })
    try session.recv() catch {
      @core_ws.WsError(
        kind=Closed({ code: Other(4001), reason: "finished", }),
        ..
      ) => ()
      _ => fail("close frame was lost")
    } noraise {
      _ => fail("session remained open")
    }
    if url.has_suffix("?shutdown") {
      let next = @ws.connect(url, subprotocols=["echo"])
      defer next.abort()
      assert_eq(next.recv(), Text("ready"))
      next.send(Text("before stop"))
      assert_eq(next.recv(), Text("before stop"))
      stop_host(url).wait()
      try next.recv() catch {
        @core_ws.WsError(kind=Closed({ code: GoingAway, .. }), ..) => ()
        _ => fail("shutdown did not send GoingAway")
      } noraise {
        _ => fail("shutdown left the session open")
      }
    }
    println("CASE websocket ok text binary protocol close shutdown")
  }) catch {
    @core_ws.WsError(kind~, detail~) =>
      println("CASE websocket fail \{Repr(kind)}: \{detail}")
    error => println("CASE websocket fail \{error}")
  }
}

///|
#cfg(target="js")
extern "js" fn stop_host(url : String) -> @js_async.Promise[Unit] =
  #| async url => { const target = new URL('/shutdown', url.replace(/^ws/, 'http')); await fetch(target); }
