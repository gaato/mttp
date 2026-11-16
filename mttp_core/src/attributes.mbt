///|
/// sttp-shared AttributeMap without Any: per-key slot plus closures.
pub struct AttributeKey[T] {
  priv id : Int32
  priv name : String
  priv slot : Ref[T?]
}

///|
let next_key : Ref[Int32] = { val: 0, }

///|
/// Creates a distinct typed key; identical names do not alias keys.
pub fn[T] AttributeKey::new(name : String) -> AttributeKey[T] {
  next_key.val += 1
  { id: next_key.val, name, slot: { val: None, }, }
}

///|
/// Returns the key's diagnostic name.
pub fn[T] AttributeKey::name(self : AttributeKey[T]) -> String {
  self.name
}

///|
/// Immutable associations of typed keys to local metadata.
pub struct Attributes {
  priv entries : Map[Int32, () -> Unit]
}

///|
/// Creates an empty attribute collection.
pub fn Attributes::empty() -> Attributes {
  { entries: Map([]), }
}

///|
/// Associates a value with a key on an independent copy.
pub fn[T] Attributes::put(
  self : Attributes,
  key : AttributeKey[T],
  value : T,
) -> Attributes {
  let m = self.entries.copy()
  m[key.id] = () => key.slot.val = Some(value)
  { entries: m, }
}

///|
/// Looks up a value with its original type, without consuming it.
pub fn[T] Attributes::get(self : Attributes, key : AttributeKey[T]) -> T? {
  match self.entries.get(key.id) {
    Some(f) => {
      f()
      let v = key.slot.val
      key.slot.val = None
      v
    }
    None => None
  }
}

///|
/// Set by server adapters.
pub let remote_addr : AttributeKey[String] = AttributeKey::new("remote_addr")

///|
/// The scheme the connection was accepted under, `http` or `https`, never
/// taken from the request target: a client can write an `https` target over
/// a cleartext connection, so only this says whether TLS carried the
/// request. Set by server adapters that know it (h1server from its `scheme`,
/// the Router in process from the request's own scheme); unset when
/// unknown, as on the JS fetch hosts, whose request URL may keep a
/// client-written scheme.
pub let connection_scheme : AttributeKey[String] = AttributeKey::new(
  "connection_scheme",
)

///|
/// `scheme` as a `connection_scheme` value: `http` or `https`, case aside,
/// or None for anything else, which is left unset.
pub fn connection_scheme_of(scheme : String) -> String? {
  match scheme.to_lower() {
    "http" => Some("http")
    "https" => Some("https")
    _ => None
  }
}

///|
/// Adapter-owned scheduling for work that may outlive the response. Invoke
/// during request handling; the adapter owns completion and shutdown policy.
pub let background : AttributeKey[(async () -> Unit) -> Unit] = AttributeKey::new(
  "background",
)

///|
/// Set on a response by its handler: a streamed response with this attribute
/// set to true is closed when the server starts to shut down, instead of
/// being drained; for endless streams such as server-sent events, whose
/// clients reconnect. The server stops pulling the body, closes it and ends
/// the response at the point the stream had reached (a chunked body with its
/// last chunk, otherwise by closing the connection), so shutdown does not
/// wait out its drain time for a stream that never ends by itself.
///
/// ```mbt check
/// test {
///   let response = @mttp_core.Response::new(200)
///   let response = {
///     ..response,
///     attributes: response.attributes.put(@mttp_core.close_on_shutdown, true),
///   }
///   assert_eq(response.attributes.get(@mttp_core.close_on_shutdown), Some(true))
/// }
/// ```
pub let close_on_shutdown : AttributeKey[Bool] = AttributeKey::new(
  "close_on_shutdown",
)

///|
/// Set on a response by its handler: the server will not read the rest of
/// the request body, so the engine need not wait for it, as when a body
/// exceeded the handler's bound. An HTTP/1.1 server ends the connection
/// after the response (it sends `Connection: close` and does not drain);
/// an HTTP/2 or HTTP/3 server would reset only the request's stream
/// (RFC 9113, section 8.1). It replaces a handler-written Connection
/// header, which only HTTP/1.1 has.
pub let abandon_request_body : AttributeKey[Bool] = AttributeKey::new(
  "abandon_request_body",
)

///|
/// The protocol that carried a message, as its ALPN identifier (`http/1.0`,
/// `http/1.1`, `h2`, `h3`): set by a backend on a response and by a server
/// engine on a request, when it knows (CONTRACT.md, Backend rule 11). JS
/// fetch cannot tell, so its responses leave it unset.
pub let protocol : AttributeKey[String] = AttributeKey::new("protocol")

///|
/// A caller's statement that resending this request is safe even after it
/// was written (discord's REPLAY_SAFE_HEADER, without a wire header).
pub let replay_safe : AttributeKey[Bool] = AttributeKey::new("replay_safe")

///|
/// An idempotent method or an explicit replay_safe statement. A header alone
/// cannot establish the remote service's deduplication contract.
pub fn is_idempotent(req : Request) -> Bool {
  req.meth.is_idempotent() || req.attributes.get(replay_safe) == Some(true)
}
