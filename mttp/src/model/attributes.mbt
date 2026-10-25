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
/// A caller's statement that resending this request is safe even after it
/// was written (discord's REPLAY_SAFE_HEADER, without a wire header).
pub let replay_safe : AttributeKey[Bool] = AttributeKey::new("replay_safe")

///|
/// gaato/http's rule, kept: an idempotent method, an Idempotency-Key
/// header, or the replay_safe attribute.
pub fn is_idempotent(req : Request) -> Bool {
  req.meth.is_idempotent() ||
  req.headers.get("idempotency-key") is Some(_) ||
  req.attributes.get(replay_safe) == Some(true)
}
