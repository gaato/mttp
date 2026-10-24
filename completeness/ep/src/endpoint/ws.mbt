///|
/// Typed messages over a WebSocket.
pub struct WsCodec[T] {
  priv decode : (@model.Frame) -> T raise @schema.DecodeFailure
  priv encode : (T) -> @model.Frame
  priv schema : @schema.Schema
}

///|
pub fn[T] ws_json(codec : @schema.JsonCodec[T]) -> WsCodec[T] {
  {
    decode: f => match f {
      Text(s) => {
        let j = @json.parse(s) catch { e => raise Malformed(e.to_string()) }
        codec.from_json(j)
      }
      _ => raise Mismatch(expected="text frame", actual="binary frame")
    },
    encode: v => Text(codec.to_json(v).stringify()),
    schema: codec.schema(),
  }
}

///|
/// One side of a typed conversation: receives `In`, sends `Out`.
pub struct WsChannel[In, Out] {
  recv : async () -> In?
  send : async (Out) -> Unit
  close : () -> Unit
}

///|
fn[In, Out] channel(
  io : &@model.WebSocketIo,
  inbound : WsCodec[In],
  outbound : WsCodec[Out],
) -> WsChannel[In, Out] {
  {
    recv: async fn() {
      match io.recv() {
        None | Some(Close(..)) => None
        Some(frame) => Some((inbound.decode)(frame))
      }
    },
    send: async fn(v) { io.send((outbound.encode)(v)) },
    close: () => io.close(),
  }
}

///|
/// A WebSocket endpoint: its own type, as client4 keeps WebSocket requests
/// apart (no capability type parameter).
pub struct WsEndpoint[S, I, E, In, Out] {
  priv base : Endpoint[S, I, E, Unit]
  priv inbound : WsCodec[In]
  priv outbound : WsCodec[Out]
}

///|
pub fn[S, I, E, O, In, Out] Endpoint::websocket(
  self : Endpoint[S, I, E, O],
  inbound : WsCodec[In],
  outbound : WsCodec[Out],
) -> WsEndpoint[S, I, E, In, Out] {
  { base: self.output(no_content()), inbound, outbound }
}

///|
/// Security and inputs are decoded (and failures answered) before the
/// upgrade; the handler then owns the channel.
pub fn[S, I, E, In, Out, P] WsEndpoint::serve(
  self : WsEndpoint[S, I, E, In, Out],
  authenticate : async (S) -> P,
  handle : async (P, I, WsChannel[In, Out]) -> Unit,
) -> ServerEndpoint {
  let inner = self.base.serve(authenticate, async fn(p, i) {
    ignore((p, i))
  })
  let doc = inner.doc
  {
    doc,
    run: async fn(req, captures, options) {
      let head = { request: req, captures }
      let sec = self.base.security.decode_head(head) catch {
        InputErrors(fs) =>
          return Respond((options.decode_failure)({ doc, failures: fs, security: true }))
      }
      let s = sec.finish(NoBody) catch {
        InputErrors(fs) =>
          return Respond((options.decode_failure)({ doc, failures: fs, security: true }))
      }
      let p = authenticate(s) catch {
        e => return Respond(error_response(self.base.errors, doc, e, options))
      }
      let inp = self.base.input.decode_head(head) catch {
        InputErrors(fs) =>
          return Respond((options.decode_failure)({ doc, failures: fs, security: false }))
      }
      let i = inp.finish(NoBody) catch {
        InputErrors(fs) =>
          return Respond((options.decode_failure)({ doc, failures: fs, security: false }))
      }
      Upgrade({ status: @model.Status(101), headers: @model.Headers::new() }, async fn(
        io,
      ) {
        handle(p, i, channel(io, self.inbound, self.outbound))
      })
    },
  }
}

///|
/// Client side: the caller sends `In` and receives `Out`.
pub async fn[S, I, E, In, Out, R] WsEndpoint::connect(
  self : WsEndpoint[S, I, E, In, Out],
  backend : &@client.WebSocketBackend,
  base : @model.Uri,
  security : S,
  input : I,
  use_ : async (WsChannel[Out, In]) -> R,
) -> R {
  let sink = RequestSink::new()
  self.base.security.encode(security, sink)
  self.base.input.encode(input, sink)
  let segments = self.base.segments.map(s => match s {
    Lit(l) => l
    Cap(n) => sink.captures.get(n).unwrap_or("")
  })
  let (_, io) = backend.open({
    meth: Get,
    uri: { ..base.with_segments(segments), query: sink.query },
    headers: sink.headers,
    body: Empty,
  })
  defer io.close()
  use_(channel(io, self.outbound, self.inbound))
}

///|
/// Sans-IO test double: scripted inbound frames, recorded outbound ones.
pub struct ScriptedWs {
  priv inbound : Array[@model.Frame]
  priv mut next : Int
  sent : Array[@model.Frame]
}

///|
pub fn ScriptedWs::new(inbound : Array[@model.Frame]) -> ScriptedWs {
  { inbound, next: 0, sent: [] }
}

///|
pub impl @model.WebSocketIo for ScriptedWs with recv(self) {
  if self.next >= self.inbound.length() {
    return None
  }
  self.next += 1
  Some(self.inbound[self.next - 1])
}

///|
pub impl @model.WebSocketIo for ScriptedWs with send(self, f) {
  self.sent.push(f)
}

///|
pub impl @model.WebSocketIo for ScriptedWs with close(_) {
  ()
}
