///|
/// An accepted client upgrade. Copies share acquisition state: take_conn
/// transfers the connection and all bytes read past the HTTP head once.
/// The receiver closes the connection, which releases its engine's slot.
/// Until taken, its engine or Client reclaims it on close or failed delivery.
pub(open) trait Upgraded {
  fn take_conn(Self) -> (&Conn, Bytes)?
}

///|
/// Set by an engine on an accepted 101. Closing the HTTP response body does
/// not close this connection; the upgraded owner must take and close it.
pub let upgraded : @mttp_core.AttributeKey[&Upgraded] = @mttp_core.AttributeKey::new(
  "upgraded",
)

///|
/// Set by a server handler on a 101. After writing the head the engine
/// transfers its connection and read-ahead to this callback, retaining its
/// slot until return. The stopping probe lets the protocol drain at shutdown.
/// The HTTP reader is joined first; HTTP deadlines end before this callback.
pub let upgrade : @mttp_core.AttributeKey[
  async (&Conn, Bytes, () -> Bool) -> Unit noraise,
] = @mttp_core.AttributeKey::new("upgrade")

///|
/// Disposes of protocol ownership when an attribute-bearing response is
/// discarded. Take-once acquisition makes repeated cleanup harmless and
/// leaves a connection already claimed by the caller untouched. Close the
/// response body separately, since this function owns only the hand-over.
pub fn close_unclaimed(attributes : @mttp_core.Attributes) -> Unit {
  if attributes.get(upgraded) is Some(upgrade) &&
    upgrade.take_conn() is Some((conn, _)) {
    conn.close()
  }
}

///|
/// Tracks only unclaimed upgrades so an engine or Client can reclaim them on
/// close. Taking or discarding an upgrade removes it immediately; completed
/// history is never retained. Claimed connections belong to their caller.
pub struct Upgrades {
  priv mut pending : Map[Int64, TrackedUpgrade]
  priv mut next_id : Int64
  priv mut closed : Bool
}

///|
priv struct TrackedUpgrade {
  owner : Upgrades
  id : Int64
  inner : &Upgraded
  mut available : Bool
}

///|
impl Upgraded for TrackedUpgrade with fn take_conn(self) {
  if !self.available {
    return None
  }
  self.available = false
  self.owner.pending.remove(self.id)
  self.inner.take_conn()
}

///|
/// Creates an empty owner, with no runtime or detached cleanup task.
pub fn Upgrades::new() -> Upgrades {
  { pending: Map([]), next_id: 0L, closed: false, }
}

///|
/// Registers the response's hand-over, preserving its other attributes. A
/// response arriving after close is reclaimed at once, so a concurrent send
/// cannot resurrect an owner that has already been shut down.
pub fn Upgrades::track(
  self : Upgrades,
  response : @mttp_core.Response,
) -> @mttp_core.Response {
  guard response.attributes.get(upgraded) is Some(inner) else {
    return response
  }
  if self.closed {
    close_unclaimed(response.attributes)
    return response
  }
  self.next_id += 1L
  let tracked = TrackedUpgrade::{
    owner: self,
    id: self.next_id,
    inner,
    available: true,
  }
  self.pending[tracked.id] = tracked
  { ..response, attributes: response.attributes.put(upgraded, tracked), }
}

///|
/// Reclaims all unclaimed connections exactly once and refuses late arrivals.
pub fn Upgrades::close(self : Upgrades) -> Unit {
  self.closed = true
  let pending = self.pending
  self.pending = Map([])
  for _, upgrade in pending {
    if Upgraded::take_conn(upgrade) is Some((conn, _)) {
      conn.close()
    }
  }
}
