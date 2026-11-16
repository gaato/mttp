///|
priv struct Upgrade {
  limits : @ws.WsLimits
  protocol : String?
  handler : async (&@ws.Session) -> Unit
}

///|
/// Attaches a JS host upgrade to a validated 101 response. ws.upgrade owns
/// handshake validation; fetch_handler consumes this metadata before using
/// the ordinary Web Response constructor, which rejects status 101.
pub fn websocket_upgrade(
  response : @mttp_core.Response,
  limits : @ws.WsLimits,
  protocol : String?,
  handler : async (&@ws.Session) -> Unit,
) -> @mttp_core.Response {
  {
    ..response,
    attributes: response.attributes.put(host_upgrade, Upgrade::{
      limits,
      protocol,
      handler,
    }),
  }
}

///|
let host_upgrade : @mttp_core.AttributeKey[Upgrade] = @mttp_core.AttributeKey::new(
  "host.ws.upgrade",
)

///|
fn Upgrade::respond(
  self : Upgrade,
  request : HostRequest,
  headers : @mttp_core.Headers,
  schedule : (async () -> Unit) -> Unit,
) -> HostResponse {
  let pairs = headers
    .iter()
    .map(pair => FixedArray::from_array([pair.0, pair.1]))
    .collect()
  let ready : Ref[HostSession?] = Ref(None)
  let changed = @cond_var.Cond()
  let live = Ref(true)
  let response = upgrade_response(
    request,
    self.protocol.unwrap_or(""),
    FixedArray::from_array(pairs),
    socket => {
      let session = new_session(socket, self.limits, self.protocol)
      if !live.val {
        session.abort()
      }
      ready.val = Some(session)
      changed.broadcast()
      defer_turn(turn)
      () => {
        ignore(
          @js_async.Promise::from_async(() => {
            session.close({ code: GoingAway, reason: "host shutdown", })
          }),
        )
      }
    },
  )
  if response.upgraded() {
    schedule(() => {
      defer {
        live.val = false
        if ready.val is Some(session) {
          session.abort()
        }
      }
      @async.with_timeout(self.limits.send_timeout_ms.max(1), () => {
        while ready.val is None {
          changed.wait()
        }
        let session = ready.val.unwrap()
        while session.handle.state() == 0 {
          @async.sleep(1)
        }
      })
      let session = ready.val.unwrap()
      (self.handler)(session) catch {
        @ws.WsError(kind=Closed(_), ..) => ()
        error => raise error
      }
    })
  }
  response
}

///|
extern "js" fn HostResponse::upgraded(self : HostResponse) -> Bool =
  #| response => response.status === 101 || !!response[Symbol.for('gaato.mttp.bunUpgraded')]

///|
extern "js" fn upgrade_response(
  request : HostRequest,
  protocol : String,
  headers : FixedArray[FixedArray[String]],
  start : (Socket) -> () -> Unit,
) -> HostResponse =
  #| (request, protocol, pairs, start) => {
  #|   const headers = new Headers(pairs);
  #|   const manage = socket => {
  #|     const stop = start(socket);
  #|     return signal => {
  #|       if (socket.readyState >= 2) return;
  #|       const cleanup = () => { signal.removeEventListener('abort', shutdown); socket.removeEventListener('close', cleanup); };
  #|       const shutdown = () => { cleanup(); stop(); };
  #|       socket.addEventListener('close', cleanup, {once: true});
  #|       signal.addEventListener('abort', shutdown, {once: true});
  #|       if (signal.aborted) shutdown();
  #|     };
  #|   };
  #|   const mark = (response, listen) => {
  #|     Object.defineProperty(response, Symbol.for('gaato.mttp.closeOnShutdown'), {value: listen});
  #|     return response;
  #|   };
  #|   if (typeof WebSocketPair === 'function') {
  #|     const pair = new WebSocketPair();
  #|     pair[1].accept(); start(pair[1]);
  #|     return new Response(null, {status: 101, headers, webSocket: pair[0]});
  #|   }
  #|   if (typeof globalThis.Deno?.upgradeWebSocket === 'function') {
  #|     const {socket, response} = Deno.upgradeWebSocket(request, {protocol: protocol || undefined, idleTimeout: 0});
  #|     return mark(response, manage(socket));
  #|   }
  #|   const server = request[Symbol.for('gaato.mttp.bunServer')];
  #|   if (server) {
  #|     // Bun's upgrade returns no Response. The shim unwraps this sentinel.
  #|     let signal, listen;
  #|     const data = {start(socket) { listen = manage(socket); if (signal) listen(signal); }};
  #|     return server.upgrade(request, {headers, data}) ? mark({[Symbol.for('gaato.mttp.bunUpgraded')]: true}, s => { signal = s; listen?.(s); }) : new Response(null, {status: 500});
  #|   }
  #|   return new Response('WebSocket upgrade is unavailable in this fetch host', {status: 501});
  #| }
