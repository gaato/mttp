///|
priv struct UpgradeProbe {
  closes : Ref[Int32]
  mut taken : Bool
}

///|
impl Conn for UpgradeProbe with fn read(_, max_len~) {
  ignore(max_len)
  None
}

///|
impl Conn for UpgradeProbe with fn write(_, bytes) {
  ignore(bytes)
}

///|
impl Conn for UpgradeProbe with fn close(self) {
  self.closes.val += 1
}

///|
impl Upgraded for UpgradeProbe with fn take_conn(self) {
  if self.taken {
    return None
  }
  self.taken = true
  Some((self, b"pending"))
}

///|
fn probe_response() -> (UpgradeProbe, @mttp_core.Response) {
  let probe = UpgradeProbe::{ closes: Ref(0), taken: false, }
  let response = @mttp_core.Response::new(101)
  (probe, { ..response, attributes: response.attributes.put(upgraded, probe), })
}

///|
test "upgrade owners remove claimed and discarded history and preserve other attributes" {
  let first = Upgrades::new()
  let second = Upgrades::new()
  let marker : @mttp_core.AttributeKey[Int32] = @mttp_core.AttributeKey::new(
    "marker",
  )
  for i in 0..<1024 {
    let (probe, response) = probe_response()
    let response = {
      ..response,
      attributes: response.attributes.put(marker, i),
    }
    let response = second.track(first.track(response))
    assert_eq((first.pending.length(), second.pending.length()), (1, 1))
    assert_eq(response.attributes.get(marker), Some(i))
    if i % 2 == 0 {
      response.attributes.get(upgraded).unwrap().take_conn().unwrap().0.close()
    } else {
      close_unclaimed(response.attributes)
    }
    close_unclaimed(response.attributes)
    assert_eq(probe.closes.val, 1)
    assert_eq((first.pending.length(), second.pending.length()), (0, 0))
  }
  first.close()
  second.close()
}

///|
test "upgrade owner close drains pending entries and late arrivals exactly once" {
  let owner = Upgrades::new()
  assert_eq(owner.track(@mttp_core.Response::new(200)).status, 200)
  let (probe, response) = probe_response()
  let response = owner.track(response)
  assert_eq(owner.pending.length(), 1)
  owner.close()
  owner.close()
  close_unclaimed(response.attributes)
  assert_eq(probe.closes.val, 1)
  let (late, response) = probe_response()
  let response = owner.track(response)
  close_unclaimed(response.attributes)
  close_unclaimed(@mttp_core.Attributes::empty())
  assert_eq(late.closes.val, 1)
  assert_eq(owner.pending.length(), 0)
  let inner = Upgrades::new()
  let outer = Upgrades::new()
  let (nested, response) = probe_response()
  let response = outer.track(inner.track(response))
  inner.close()
  close_unclaimed(response.attributes)
  outer.close()
  assert_eq(nested.closes.val, 1)
  assert_eq(outer.pending.length(), 0)
}
