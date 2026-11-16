///|
priv struct CloseProbe {
  closes : Ref[Int32]
}

///|
impl @rt.Conn for CloseProbe with fn read(_, max_len~) {
  ignore(max_len)
  None
}

///|
impl @rt.Conn for CloseProbe with fn write(_, bytes) {
  ignore(bytes)
}

///|
impl @rt.Conn for CloseProbe with fn close(self) {
  self.closes.val += 1
}

///|
priv struct SlotSignal {}

///|
impl @rt.Signal for SlotSignal with fn wait(_) {
  ()
}

///|
impl @rt.Signal for SlotSignal with fn notify(_) {
  ()
}

///|
priv struct SlotCoordination {}

///|
impl @rt.Coordination for SlotCoordination with fn signal(_) {
  SlotSignal::{ }
}

///|
impl @rt.Coordination for SlotCoordination with fn protect(_, work~) {
  work()
}

///|
impl @rt.Coordination for SlotCoordination with fn supervise(
  _,
  primary~,
  monitor~,
) {
  ignore(monitor)
  primary()
}

///|
test "unclaimed upgrade disposal frees a real slot once without freeing its successor" {
  for claim in [false, true] {
    let slots = Slots::new(
      coordination=SlotCoordination::{ },
      max_total=1,
      max_per_origin=1,
    )
    let first = slots.enqueue("origin")
    assert_true(first.state is Granted)
    let second = slots.enqueue("origin")
    assert_true(second.state is Waiting)
    let conn = CloseProbe::{ closes: Ref(0), }
    let upgrade : &@rt.Upgraded = Upgrade::{
      conn: { wire: Wire::new(conn), slots, key: "origin", closed: false, },
      pending: Some(b""),
    }
    let owner = @rt.Upgrades::new()
    let response = @mttp_core.Response::new(101)
    let response = owner.track({
      ..response,
      attributes: response.attributes.put(@rt.upgraded, upgrade),
    })
    let taken = if claim {
      Some(
        response.attributes.get(@rt.upgraded).unwrap().take_conn().unwrap().0,
      )
    } else {
      None
    }
    owner.close()
    if taken is Some(taken) {
      assert_eq(conn.closes.val, 0)
      assert_true(second.state is Waiting)
      taken.close()
    }
    assert_eq(conn.closes.val, 1)
    assert_true(second.state is Granted)
    assert_eq(slots.control.in_use, 1)
    @rt.close_unclaimed(response.attributes)
    owner.close()
    assert_eq(conn.closes.val, 1)
    assert_eq(slots.control.in_use, 1)
    slots.abandon(second)
    assert_eq(slots.control.in_use, 0)
    assert_eq(slots.control.per_origin.get("origin").unwrap_or(0), 0)
  }
}
