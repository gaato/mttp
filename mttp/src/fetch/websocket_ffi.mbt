///|
#external
priv type Socket

///|
#external
priv type Handle

///|
#external
priv type HostRequest

///|
#external
priv type HostResponse

///|
#external
priv type Scope

///|
// The shared MoonBit scheduler can resume a task in another request. Host
// operations and their Promise::wait callbacks must run in their owner's
// context: Workers drops reactions owned by an ended request.
extern "js" fn Scope::new() -> Scope =
  #| () => {
  #|   const operations = []; let dispatch;
  #|   const pump = async () => {
  #|     for (;;) {
  #|       await new Promise(resolve => { dispatch = resolve; });
  #|       while (operations.length) operations.shift()();
  #|     }
  #|   };
  #|   pump();
  #|   const enqueue = run => { operations.push(run); dispatch(); };
  #|   return {operations, run(start) {
  #|     let result;
  #|     enqueue(() => { result = Promise.resolve().then(start); result.catch(() => {}); });
  #|     // Returning a native Promise would register the observer in the
  #|     // scheduler caller's context. Subscribe inside the owner instead.
  #|     return {then(resolve, reject) { enqueue(() => result.then(resolve, reject)); }};
  #|   }};
  #| }

///|
priv struct Event {
  kind : Int32
  text : String
  data : Bytes
  code : Int32
  reason : String
}

///|
// Events only notify the receiver. Taking a message happens in MoonBit after
// the cancellable wait, so cancellation never consumes a committed message.
fn attach(socket : Socket, bytes : Int32, count : Int32) -> Handle {
  attach_scoped(socket, bytes, count, Scope::new(), turn)
}

///|
fn turn() -> Unit {
  ignore(@js_async.Promise::from_async(() => ()))
}

///|
extern "js" fn defer_turn(turn : () -> Unit) -> Unit =
  #| turn => { queueMicrotask(turn); }

///|
extern "js" fn attach_scoped(
  socket : Socket,
  bytes : Int32,
  count : Int32,
  scope : Scope,
  turn : () -> Unit,
) -> Handle =
  #| (socket, bytes, count, scope, turn) => {
  #|   socket.binaryType = 'arraybuffer';
  #|   const empty = new Uint8Array(0);
  #|   const h = {socket, queue: [], bytes: 0, terminal: null, wake: null, closing: false, state: socket.readyState, protocol: socket.protocol || ''};
  #|   h.operations = scope.operations;
  #|   h.run = run => scope.run(run);
  #|   const event = (kind, code = 0, reason = '') => ({kind, text: '', data: empty, code, reason});
  #|   // Cancellation joins can need another scheduler round after the last
  #|   // socket event. Keep that round in the owner too, and coalesce bursts
  #|   // so inbound events cannot grow the operation queue with empty ticks.
  #|   let tickQueued = false;
  #|   h.notify = () => {
  #|     h.wake?.();
  #|     if (!tickQueued) {
  #|       tickQueued = true;
  #|       h.run(() => { tickQueued = false; turn(); }).then(() => {}, () => {});
  #|     }
  #|   };
  #|   h.close = (code, reason) => {
  #|     if (h.closing || h.state === 3) return;
  #|     h.closing = true; h.state = 2;
  #|     h.run(() => {
  #|       try { if (code === 1005 && !reason) socket.close(); else socket.close(code, reason); }
  #|       catch (_) {
  #|         // Web-standard clients restrict close() to 1000 or application codes.
  #|         try { socket.close(code >= 1000 && code < 2000 ? code + 3000 : 4008, reason); }
  #|         catch (_) { try { socket.close(); } catch (_) {} }
  #|       }
  #|     }).then(() => {}, () => {});
  #|   };
  #|   h.fail = (kind, code, reason) => {
  #|     if (h.terminal) return;
  #|     h.queue.length = 0; h.bytes = 0;
  #|     h.terminal = event(kind, code, reason);
  #|     h.close(code, reason); h.detach(); h.notify();
  #|   };
  #|   const message = e => {
  #|     if (h.terminal || h.closing) return;
  #|     let item, size;
  #|     if (typeof e.data === 'string') {
  #|       size = new TextEncoder().encode(e.data).length;
  #|       item = {...event(0), text: e.data};
  #|     } else {
  #|       const value = e.data;
  #|       if (!(value instanceof ArrayBuffer) && !ArrayBuffer.isView(value)) {
  #|         h.fail(4, 1003, 'unsupported host payload'); return;
  #|       }
  #|       size = value.byteLength;
  #|       if (size > bytes || size > bytes - h.bytes) { h.fail(3, 1009, 'inbound byte limit'); return; }
  #|       item = {...event(1), data: value instanceof ArrayBuffer ? new Uint8Array(value) :
  #|         new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice()};
  #|     }
  #|     if (size > bytes || size > bytes - h.bytes) { h.fail(3, 1009, 'inbound byte limit'); return; }
  #|     if (h.queue.length >= count) { h.fail(4, 1008, 'inbound message count limit'); return; }
  #|     h.queue.push({item, size}); h.bytes += size; h.notify();
  #|   };
  #|   const close = e => {
  #|     h.state = 3;
  #|     h.terminal ??= event(2, e.code || 1005, e.reason || '');
  #|     h.detach();
  #|     h.notify();
  #|   };
  #|   const error = () => h.fail(5, 1011, 'host WebSocket error');
  #|   const opened = () => { h.state = 1; h.protocol = socket.protocol || ''; };
  #|   h.detach = () => {
  #|     socket.removeEventListener('message', message);
  #|     socket.removeEventListener('error', error);
  #|     socket.removeEventListener('close', close);
  #|     socket.removeEventListener('open', opened);
  #|   };
  #|   socket.addEventListener('message', message);
  #|   socket.addEventListener('error', error);
  #|   socket.addEventListener('close', close);
  #|   socket.addEventListener('open', opened);
  #|   return h;
  #| }

///|
extern "js" fn open_socket(
  url : String,
  protocols : FixedArray[String],
  headers : FixedArray[FixedArray[String]],
  make : (Socket) -> Handle,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[Handle] =
  #| async (url, protocols, headers, make, signal) => {
  #|   if (typeof WebSocketPair === 'function') {
  #|     const target = new URL(url); target.protocol = target.protocol === 'wss:' ? 'https:' : 'http:';
  #|     const fields = new Headers(headers); fields.set('Upgrade', 'websocket');
  #|     if (protocols.length) fields.set('Sec-WebSocket-Protocol', protocols.join(', '));
  #|     const reply = await fetch(target, {headers: fields, signal, redirect: 'manual'});
  #|     if (reply.status !== 101 || !reply.webSocket) throw new Error(`upgrade status ${reply.status}`);
  #|     const socket = reply.webSocket;
  #|     const protocol = reply.headers.get('Sec-WebSocket-Protocol') || '';
  #|     if ((protocol && !protocols.includes(protocol)) || signal.aborted) { socket.close(); throw new Error('invalid or cancelled upgrade'); }
  #|     socket.accept(); const h = make(socket); h.negotiated = protocol; return h;
  #|   }
  #|   if (headers.length && !globalThis.Bun) throw new Error('custom headers require Bun or Workers fetch upgrade');
  #|   // Bun accepts Headers in its options overload, preserving repeated list
  #|   // fields in arrival order instead of replacing them in a plain object.
  #|   const socket = globalThis.Bun ? new WebSocket(url, {protocols, headers: new Headers(headers)}) : new WebSocket(url, protocols);
  #|   const h = make(socket);
  #|   try {
  #|     await new Promise((resolve, reject) => {
  #|       const cleanup = () => { socket.removeEventListener('open', opened); socket.removeEventListener('close', failed);
  #|         socket.removeEventListener('error', failed); signal.removeEventListener('abort', aborted); };
  #|       const opened = () => { cleanup(); resolve(); };
  #|       const failed = () => { cleanup(); reject(new Error('WebSocket handshake failed')); };
  #|       const aborted = () => { cleanup(); h.fail(2, 1006, 'aborted'); reject(new DOMException('aborted', 'AbortError')); };
  #|       socket.addEventListener('open', opened); socket.addEventListener('close', failed); socket.addEventListener('error', failed);
  #|       signal.addEventListener('abort', aborted, {once: true}); if (signal.aborted) aborted();
  #|     });
  #|     return h;
  #|   } catch (e) { h.fail(2, 1006, 'handshake failed'); throw e; }
  #| }

///|
// Start and observe the handshake inside its owner's request, even when
// the timeout task group later subscribes from another scheduler turn.
extern "js" fn Scope::open(
  self : Scope,
  start : () -> @js_async.Promise[Handle],
) -> @js_async.Promise[Handle] =
  #| (scope, start) => scope.run(start)

///|
extern "js" fn Handle::wait(
  self : Handle,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[Unit] =
  #| (h, signal) => h.run(() => new Promise((resolve, reject) => {
  #|   if (h.queue.length || h.terminal) { resolve(); return; }
  #|   const cleanup = () => { h.wake = null; signal.removeEventListener('abort', abort); };
  #|   const abort = () => { cleanup(); reject(new DOMException('aborted', 'AbortError')); };
  #|   h.wake = () => { cleanup(); resolve(); };
  #|   signal.addEventListener('abort', abort, {once: true}); if (signal.aborted) abort();
  #| }))

///|
extern "js" fn Handle::take(self : Handle) -> Event =
  #| h => { const next = h.queue.shift(); if (next) { h.bytes -= next.size; return next.item; } return h.terminal; }

///|
extern "js" fn Handle::protocol(self : Handle) -> String =
  #| h => h.negotiated ?? h.protocol

///|
extern "js" fn Handle::send(
  self : Handle,
  text : String,
  data : Bytes,
  binary : Bool,
) -> @js_async.Promise[String] =
  #| (h, text, data, binary) => h.run(() => {
  #|   if (h.terminal || h.closing || h.state !== 1) return 'WebSocket is closed';
  #|   try { h.socket.send(binary ? data : text); return ''; } catch (e) { return String(e); }
  #| })

///|
extern "js" fn Handle::buffered(self : Handle) -> @js_async.Promise[Int32] =
  #| h => h.run(() => Math.min(h.socket.bufferedAmount || 0, 2147483647))

///|
extern "js" fn Handle::state(self : Handle) -> Int32 =
  #| h => h.state

///|
extern "js" fn Handle::close(
  self : Handle,
  code : Int32,
  reason : String,
) -> Unit =
  #| (h, code, reason) => h.close(code, reason)

///|
// 1005 selects close() without arguments; the local terminal stays 1006.
extern "js" fn Handle::abort(self : Handle) -> Unit =
  #| h => { if (h.aborted) return; h.aborted = true; h.queue.length = 0; h.bytes = 0; h.terminal ??= {kind: 2, text: '', data: new Uint8Array(0), code: 1006, reason: ''};
  #|   h.close(1005, ''); h.run(() => h.socket.terminate?.()).then(() => {}, () => {}); h.detach(); h.notify(); }
