///|
priv struct CodingUpgrade {
  closes : Ref[Int32]
  slots : Ref[Int32]
  mut taken : Bool
}

///|
impl @rt.Upgraded for CodingUpgrade with fn take_conn(self) {
  if self.taken {
    return None
  }
  self.taken = true
  Some((self, b""))
}

///|
impl @rt.Conn for CodingUpgrade with fn read(_, max_len~) {
  ignore(max_len)
  None
}

///|
impl @rt.Conn for CodingUpgrade with fn write(_, bytes) {
  ignore(bytes)
}

///|
impl @rt.Conn for CodingUpgrade with fn close(self) {
  self.closes.val += 1
  self.slots.val = 0
}

///|
test "Decompress head refusal reclaims an unclaimed upgrade socket and slot" {
  @driver.run_sync(() => {
    let upgrade = CodingUpgrade::{
      closes: Ref(0),
      slots: Ref(1),
      taken: false,
    }
    let response = @mttp_core.Response::new(
      200,
      headers=@mttp_core.Headers::of([
        ("content-encoding", Array::make(6, "gzip").join(",")),
      ]),
    )
    let response = {
      ..response,
      attributes: response.attributes.put(@rt.upgraded, upgrade),
    }
    let backend = @codings.Decompress::new(fixture(response))
    try
      backend.send(
        @mttp_core.Request::get("/"),
        @mttp_core.SendOptions::default(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("decode accepted")
    }
    assert_eq(upgrade.closes.val, 1)
    assert_eq(upgrade.slots.val, 0)
    backend.close()
    assert_eq(upgrade.closes.val, 1)
  })
}

///|
test "Decompress transfers 101 untouched even with invalid coding headers" {
  @driver.run_sync(() => {
    let upgrade = CodingUpgrade::{
      closes: Ref(0),
      slots: Ref(1),
      taken: false,
    }
    let response = @mttp_core.Response::new(
      101,
      headers=@mttp_core.Headers::of([
        ("content-encoding", Array::make(6, "gzip").join(",")),
      ]),
    )
    let response = {
      ..response,
      attributes: response.attributes.put(@rt.upgraded, upgrade),
    }
    let backend = @codings.Decompress::new(fixture(response))
    let response = backend.send(
      @mttp_core.Request::get("/"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(upgrade.closes.val, 0)
    response.attributes.get(@rt.upgraded).unwrap().take_conn().unwrap().0.close()
    assert_eq(upgrade.closes.val, 1)
    assert_eq(upgrade.slots.val, 0)
    backend.close()
    assert_eq(upgrade.closes.val, 1)
  })
}
