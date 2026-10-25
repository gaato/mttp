///|
#external
priv type FetchHeaders

///|
extern "js" fn FetchHeaders::new() -> FetchHeaders =
  #| () => new Headers()

///|
extern "js" fn FetchHeaders::append(
  self : FetchHeaders,
  name : String,
  value : String,
) -> Unit =
  #| (headers, name, value) => headers.append(name, value)

///|
#external
priv type FetchResponse

///|
extern "js" fn FetchResponse::status(self : FetchResponse) -> Int32 =
  #| response => response.status

///|
extern "js" fn FetchResponse::headers(
  self : FetchResponse,
) -> FixedArray[FixedArray[String]] =
  #| response => {
  #|   const headers = response.headers;
  #|   const pairs = Array.from(headers.entries());
  #|   if (typeof headers.getSetCookie !== 'function') return pairs;
  #|   return pairs.filter(([name]) => name !== 'set-cookie')
  #|     .concat(headers.getSetCookie().map(value => ['set-cookie', value]));
  #| }

///|
#external
priv type FetchReader

///|
extern "js" fn FetchResponse::reader(self : FetchResponse) -> FetchReader =
  #| response => response.body?.getReader() ?? {
  #|   read: () => Promise.resolve({done: true}),
  #|   cancel: () => Promise.resolve(), releaseLock: () => {}
  #| }

///|
priv struct FetchChunk {
  done : Bool
  value : Bytes
}

///|
extern "js" fn FetchReader::read(
  self : FetchReader,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[FetchChunk] =
  #| (reader, signal) => {
  #|   const cancel = () => reader.cancel().catch(() => {});
  #|   if (signal.aborted) cancel();
  #|   else signal.addEventListener('abort', cancel, {once: true});
  #|   return reader.read()
  #|     .then(({done, value}) => ({done, value: value ?? new Uint8Array(0)}))
  #|     .finally(() => signal.removeEventListener('abort', cancel));
  #| }

///|
extern "js" fn FetchReader::close(self : FetchReader) -> Unit =
  #| reader => {
  #|   reader.cancel().catch(() => {});
  #|   try { reader.releaseLock(); } catch (_) {}
  #| }

///|
extern "js" fn fetch_once(
  url : String,
  verb : String,
  headers : FetchHeaders,
  body : Bytes,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[FetchResponse] =
  #| (url, method, headers, body, signal) => fetch(url, {
  #|   method, headers, signal, redirect: 'manual',
  #|   body: method.toUpperCase() === 'GET' || method.toUpperCase() === 'HEAD' ? undefined : body
  #| })
