///|
/// Host Web Request, independent of the async runtime's public types.
#external
pub type JsRequest

///|
/// Host promise returned to the serverless entry point.
#external
pub type JsPromise

///|
/// Host callback receiving one aggregate background promise synchronously.
#external
pub type JsBackground

///|
/// Opaque host environment supplied explicitly by an entry shim.
#external
pub type JsEnv

///|
/// Optional host environment; absent unless with_env was used for this request.
pub let env : @model.AttributeKey[JsEnv] = @model.AttributeKey::new("fetch.env")

///|
#external
priv type Environments

///|
extern "js" fn Environments::new() -> Environments =
  #| () => new WeakMap()

///|
let environments : Environments = Environments::new()

///|
extern "js" fn Environments::put(
  self : Environments,
  request : JsRequest,
  value : JsEnv,
) -> Unit =
  #| (map, req, value) => { map.set(req, value); }

///|
extern "js" fn Environments::has(
  self : Environments,
  request : JsRequest,
) -> Bool =
  #| (map, req) => map.has(req)

///|
extern "js" fn Environments::get(
  self : Environments,
  request : JsRequest,
) -> JsEnv =
  #| (map, req) => map.get(req)

///|
/// Associates a host environment without modifying or cloning the Web Request.
pub fn with_env(request : JsRequest, value : JsEnv) -> JsRequest {
  environments.put(request, value)
  request
}

///|
extern "js" fn JsRequest::url(self : JsRequest) -> String =
  #| req => req.url

///|
extern "js" fn JsRequest::verb(self : JsRequest) -> String =
  #| req => req.method

///|
extern "js" fn JsRequest::headers(
  self : JsRequest,
) -> FixedArray[FixedArray[String]] =
  #| req => Array.from(req.headers.entries())

///|
extern "js" fn JsRequest::signal(self : JsRequest) -> @js_async.AbortSignal =
  #| req => req.signal

///|
extern "js" fn JsRequest::aborted(self : JsRequest) -> Bool =
  #| req => req.signal.aborted

///|
extern "js" fn JsRequest::reject_aborted(self : JsRequest) -> JsPromise =
  #| req => {
  #|   req.body?.cancel().catch(() => {});
  #|   return Promise.reject(new DOMException('Request aborted', 'AbortError'));
  #| }

///|
#external
priv type Reader

///|
extern "js" fn JsRequest::reader(self : JsRequest) -> @js_async.Promise[Reader] =
  #| req => Promise.resolve().then(() => {
  #| const reader = req.body?.getReader() ?? {
  #|   read: () => Promise.resolve({done: true}),
  #|   cancel: () => Promise.resolve(), releaseLock: () => {}
  #| };
  #| const state = {reader, cancelled: false};
  #| if (req.signal.aborted) { state.cancelled = true; reader.cancel().catch(() => {}); reader.releaseLock(); }
  #| return state;
  #| })

///|
priv struct Chunk {
  done : Bool
  value : Bytes
}

///|
extern "js" fn Reader::read(
  self : Reader,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[Chunk] =
  #| (state, signal) => {
  #|   const reader = state.reader;
  #|   const cancel = () => {
  #|     if (!state.cancelled) { state.cancelled = true; reader.cancel().catch(() => {}); }
  #|   };
  #|   if (signal.aborted) cancel();
  #|   else signal.addEventListener('abort', cancel, {once: true});
  #|   return reader.read().then(({done, value}) => ({done, value: value ?? new Uint8Array(0)}))
  #|     .finally(() => signal.removeEventListener('abort', cancel));
  #| }

///|
extern "js" fn Reader::close(self : Reader) -> Unit =
  #| state => {
  #|   const reader = state.reader;
  #|   if (!state.cancelled) { state.cancelled = true; reader.cancel().catch(() => {}); }
  #|   try { reader.releaseLock(); } catch (_) {}
  #| }

///|
#external
priv type Background

///|
extern "js" fn Background::new(register : JsBackground) -> Background =
  #| register => {
  #|   let resolve, reject;
  #|   const promise = new Promise((ok, no) => { resolve = ok; reject = no; });
  #|   const state = {pending: 1, failure: undefined, resolve, reject};
  #|   register(promise);
  #|   return state;
  #| }

///|
extern "js" fn Background::add(
  self : Background,
  promise : @js_async.Promise[Unit],
) -> Unit =
  #| (state, promise) => {
  #|   ++state.pending;
  #|   promise.catch(error => { state.failure ??= error; }).finally(() => {
  #|     if (--state.pending === 0) {
  #|       if (state.failure !== undefined) state.reject(state.failure);
  #|       else state.resolve();
  #|     }
  #|   });
  #| }

///|
extern "js" fn Background::finish(self : Background) -> Unit =
  #| state => {
  #|   if (--state.pending === 0) {
  #|     if (state.failure !== undefined) state.reject(state.failure);
  #|     else state.resolve();
  #|   }
  #| }

///|
#external
priv type WebResponse

///|
extern "js" fn exported(promise : @js_async.Promise[WebResponse]) -> JsPromise =
  #| promise => promise

///|
extern "js" fn response(
  status : Int32,
  headers : FixedArray[FixedArray[String]],
  no_body : Bool,
  pull : (@js_async.AbortSignal) -> @js_async.Promise[Chunk],
  close : () -> Unit,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[WebResponse] =
  #| (status, pairs, noBody, pull, close, signal) => Promise.resolve().then(() => {
  #|   if (noBody) { close(); return new Response(null, {status, headers: pairs}); }
  #|   let closed = false, controller;
  #|   const abort = new AbortController();
  #|   const finish = () => {
  #|     if (closed) return;
  #|     closed = true;
  #|     signal.removeEventListener('abort', cancel);
  #|     abort.abort();
  #|     close();
  #|   };
  #|   const cancel = () => { controller.error(new DOMException('Request aborted', 'AbortError')); finish(); };
  #|   const body = new ReadableStream({
  #|     start(c) { controller = c; },
  #|     async pull(c) {
  #|       try {
  #|         const chunk = await pull(abort.signal);
  #|         if (closed) return;
  #|         if (chunk.done) { c.close(); finish(); }
  #|         else c.enqueue(chunk.value);
  #|       } catch (error) { if (!closed) { c.error(error); finish(); } }
  #|     },
  #|     cancel() { finish(); }
  #|   }, {highWaterMark: 0});
  #|   signal.addEventListener('abort', cancel, {once: true});
  #|   if (signal.aborted) cancel();
  #|   try { return new Response(body, {status, headers: pairs}); }
  #|   catch (error) { finish(); throw error; }
  #| })
