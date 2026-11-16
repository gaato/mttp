///|
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
async fn open(base : String, path : String) -> &@core_ws.Session {
  let backend = @backend.AsyncBackend::new(
    config=@h1client.ClientConfig::default(),
  )
  defer backend.close()
  @ws.connect(base + path, limits~, backend~)
}

///|
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
