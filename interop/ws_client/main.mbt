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
  @ws.connect(
    base + path,
    limits~,
    backend~,
    compression=@ws.Compression::new(),
  )
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
fn outcome(stage : String, error : Error) -> (String, String) {
  let (kind, detail) = match error {
    @core_ws.WsError(kind~, detail~) => {
      let name = match kind {
        Closed({ code: Normal, .. }) => "ClosedNormal"
        Closed(_) => "Closed"
        Protocol => "Protocol"
        TooLarge(_) => "TooLarge"
        Timeout(_) => "Timeout"
        Transport(_) => "Transport"
        Handshake(_) => "Handshake"
        @core_ws.WsErrorKind::.. => "OtherWsError"
      }
      (name, "\{Repr(kind)}: \{detail}")
    }
    _ => ("Other", "\{Repr(error)}")
  }
  (
    kind,
    (stage + ": " + detail)
    .replace_all(old="\r", new="\\r")
    .replace_all(old="\n", new="\\n"),
  )
}

///|
#cfg(not(target="js"))
async fn main {
  let args = @env.args()
  let base = args.get(1).unwrap_or("ws://127.0.0.1:39050")
  let count = @string.parse_int(control(base, "/getCaseCount"))
  println("Autobahn: \{count} cases")
  if args.get(2) == Some("--list-cases") {
    // Discover the pinned suite's whole inventory before selecting batches:
    // a lost result inside a wildcard row must still fail the aggregate run.
    for case in 1..<=count {
      let info = @json.parse(control(base, "/getCaseInfo?case=\{case}"))
      guard info is { "id": String(id), .. } else {
        fail("Autobahn case \{case}: missing case id")
      }
      println("Autobahn expected \{id}")
    }
    println("Autobahn inventory complete \{count}")
    return
  }
  for case in 1..<=count {
    // Compression cases allow up to 480 s in Autobahn itself.
    let (kind, detail) = @async.with_timeout(600000, () => {
      let session = open(base, "/runCase?case=\{case}&agent=mttp-client")
      defer session.abort()
      for ;; {
        let message = session.recv() catch {
          error => return outcome("recv", error)
        }
        session.send(message) catch {
          error => return outcome("send", error)
        }
      }
    }) catch {
      // Some negotiation cases intentionally fail the opening handshake.
      // Continue so Autobahn can report that exact verdict and later cases.
      error => outcome("open/timeout", error)
    }
    println("Autobahn outcome \{case} \{kind}: \{detail}")
  }
  // Autobahn can end this control connection after writing its reports.
  // The adapter checks reports/index.json to decide whether it succeeded.
  ignore(control(base, "/updateReports?agent=mttp-client")) catch {
    error => {
      let (kind, detail) = outcome("control", error)
      println("Autobahn updateReports ended: \{kind}: \{detail}")
    }
  }
}

///|
#cfg(target="js")
async fn main {
  @async.with_timeout(10000, () => {
    let args = @env.args()
    let url = args.get(args.length() - 1).unwrap_or("ws://127.0.0.1:39507/")
    if is_bun() {
      let headers = @ws.connect(
        url + "headers",
        subprotocols=["echo"],
        headers=@mttp_core.Headers::of([
          ("Accept", "text/plain"),
          ("accept", "application/json"),
        ]),
      )
      defer headers.abort()
      headers.send(Text("headers retained"))
      assert_eq(headers.recv(), Text("headers retained"))
      headers.close({ code: Normal, reason: "", })
    }
    if url.has_suffix("?shutdown") {
      assert_true(check_upgrade_headers(url).wait())
    }
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

///|
#cfg(target="js")
extern "js" fn is_bun() -> Bool =
  #| () => !!globalThis.Bun

///|
#cfg(target="js")
extern "js" fn check_upgrade_headers(url : String) -> @js_async.Promise[Bool] =
  #| async url => {
  #|   const {connect} = await import('node:net');
  #|   const target = new URL(url);
  #|   return new Promise((resolve, reject) => {
  #|     const socket = connect(Number(target.port), target.hostname);
  #|     const timer = setTimeout(() => { socket.destroy(); reject(new Error('upgrade headers timed out')); }, 3000);
  #|     let text = '';
  #|     socket.on('connect', () => socket.write(`GET /ws HTTP/1.1\r\nHost: ${target.host}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: echo\r\n\r\n`));
  #|     socket.on('data', bytes => {
  #|       text += bytes.toString('latin1');
  #|       if (!text.includes('\r\n\r\n')) return;
  #|       clearTimeout(timer); socket.destroy();
  #|       const lines = text.split('\r\n\r\n')[0].split('\r\n');
  #|       const fields = name => lines.slice(1).filter(line => line.toLowerCase().startsWith(name + ':')).map(line => line.slice(line.indexOf(':') + 1).trim());
  #|       resolve(lines[0].includes('101') && fields('sec-websocket-accept')[0] === 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=' &&
  #|         fields('sec-websocket-protocol')[0] === 'echo' && JSON.stringify(fields('set-cookie')) === JSON.stringify(['a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT', 'b=2; HttpOnly']) && fields('x-app')[0] === 'kept');
  #|     });
  #|     socket.on('error', error => { clearTimeout(timer); reject(error); });
  #|   });
  #| }
