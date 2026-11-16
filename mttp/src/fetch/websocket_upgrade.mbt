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
fn host_websocket_upgrade(response : @mttp_core.Response) -> Upgrade? {
  match response.attributes.get(host_upgrade) {
    Some(upgrade) => Some(upgrade)
    None =>
      response.attributes
      .get(@ws.server_handler)
      .map(handler => Upgrade::{
        limits: @ws.WsLimits::default(),
        protocol: response.headers.get("sec-websocket-protocol"),
        handler,
      })
  }
}

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
  let stopping = Ref(false)
  let release : Ref[() -> Unit] = Ref(() => ())
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
    },
    () => {
      stopping.val = true
      changed.broadcast()
      defer_turn(turn)
    },
    cleanup => if live.val { release.val = cleanup } else { cleanup() },
  )
  if response.upgraded() {
    schedule(() => {
      defer {
        live.val = false
        (release.val)()
        if ready.val is Some(session) {
          session.abort()
        }
      }
      // Startup is part of the supervised work: a socket need not ever open.
      // The monitor can abandon a pending upgrade or close an existing socket
      // within the Close bound, independently of the longer send/open deadline.
      @async.with_task_group(group => {
        let work = group.spawn(allow_failure=true, () => {
          @async.with_timeout(self.limits.send_timeout_ms.max(1), () => {
            while ready.val is None {
              changed.wait()
            }
            let session = ready.val.unwrap()
            while session.handle.state() == 0 {
              @async.sleep(1)
            }
          })
          if !stopping.val {
            (self.handler)(ready.val.unwrap()) catch {
              @ws.WsError(kind=Closed(_), ..) => ()
              error => raise error
            }
          }
        })
        group.spawn_bg(no_wait=true, () => {
          while !stopping.val {
            changed.wait()
          }
          if ready.val is Some(session) {
            session.close({ code: GoingAway, reason: "host shutdown", })
          }
          work.cancel()
        })
        work.wait() catch {
          @async.WaitedTaskAlreadyCancelled => ()
          error => raise error
        }
      })
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
  start : (Socket) -> Unit,
  stop : () -> Unit,
  on_finish : (() -> Unit) -> Unit,
) -> HostResponse =
  #| (request, protocol, pairs, start, stop, onFinish) => {
  #|   const headers = new Headers(pairs);
  #|   let finished = false, detach = () => {};
  #|   onFinish(() => { finished = true; detach(); });
  #|   const manage = socket => {
  #|     start(socket);
  #|     return signal => {
  #|       if (finished || socket.readyState >= 2) return;
  #|       const cleanup = () => { signal.removeEventListener('abort', shutdown); socket.removeEventListener('close', cleanup); };
  #|       detach = cleanup;
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
  #|     pair[1].accept();
  #|     return mark(new Response(null, {status: 101, headers, webSocket: pair[0]}), manage(pair[1]));
  #|   }
  #|   if (typeof globalThis.Deno?.upgradeWebSocket === 'function') {
  #|     const {socket, response} = Deno.upgradeWebSocket(request, {protocol: protocol || undefined, idleTimeout: 0});
  #|     // Only the host knows its upgrade handshake fields. Append application
  #|     // pairs individually so Set-Cookie values never become a comma list.
  #|     const handshake = new Set(['connection', 'upgrade', 'sec-websocket-accept', 'sec-websocket-protocol', 'sec-websocket-extensions']);
  #|     for (const [name, value] of pairs) {
  #|       if (!handshake.has(name.toLowerCase())) response.headers.append(name, value);
  #|     }
  #|     return mark(response, manage(socket));
  #|   }
  #|   const server = request[Symbol.for('gaato.mttp.bunServer')];
  #|   if (server) {
  #|     // Bun's upgrade returns no Response. The shim unwraps this sentinel.
  #|     let signal, listen;
  #|     // Shutdown can precede Bun's open callback. Notify the monitor now;
  #|     // start() will discard a socket delivered after its owner has ended.
  #|     const beforeOpen = () => stop();
  #|     const data = {start(socket) {
  #|       signal?.removeEventListener('abort', beforeOpen);
  #|       listen = manage(socket); if (signal) listen(signal);
  #|     }};
  #|     return server.upgrade(request, {headers, data}) ? mark({[Symbol.for('gaato.mttp.bunUpgraded')]: true}, s => {
  #|       if (finished) return;
  #|       signal = s;
  #|       detach = () => s.removeEventListener('abort', beforeOpen);
  #|       if (listen) listen(s);
  #|       else if (s.aborted) stop();
  #|       else s.addEventListener('abort', beforeOpen, {once: true});
  #|     }) : new Response(null, {status: 500});
  #|   }
  #|   return new Response('WebSocket upgrade is unavailable in this fetch host', {status: 501});
  #| }
