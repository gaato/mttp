///|
test "upgrade byte pair retains at most 64 KiB and backpressures the next byte" {
  let d = @driver.Driver::new()
  let c = @sim.SimCoordination::new(d)
  let a = UpgradePipe::new(c)
  let b = UpgradePipe::new(c)
  let left : &@rt.Conn = UpgradeConn::{ input: a, output: b, }
  let right : &@rt.Conn = UpgradeConn::{ input: b, output: a, }
  d.run(() => {
    let writer = d.spawn(() => left.write(Bytes::make(65537, b'x')))
    d.pause()
    assert_eq(b.bytes.length(), 65536)
    assert_false(writer.is_finished())
    assert_eq(right.read(max_len=65536).unwrap().length(), 65536)
    d.pause()
    assert_eq(b.bytes.length(), 1)
    assert_false(writer.is_finished())
    assert_eq(right.read(max_len=2), Some(b"x"))
    ignore(writer.wait())
    let invalid = try {
      ignore(right.read(max_len=0))
      false
    } catch {
      _ => true
    }
    assert_true(invalid)
    left.close()
    assert_eq(right.read(max_len=1), None)
    let failed = try {
      right.write(b"x")
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  })
  let a = UpgradePipe::new(c)
  let b = UpgradePipe::new(c)
  let left : &@rt.Conn = UpgradeConn::{ input: a, output: b, }
  let right : &@rt.Conn = UpgradeConn::{ input: b, output: a, }
  d.run(() => {
    let refused = Ref(false)
    let writer = d.spawn(() => {
      left.write(b"pending") catch {
        _ => refused.val = true
      }
    })
    d.pause()
    right.close()
    ignore(writer.wait())
    assert_true(refused.val)
  })
}

///|
test "cancelling an upgrade byte pair writer wakes its peer and drops pending bytes" {
  let d = @driver.Driver::new()
  let c = @sim.SimCoordination::new(d)
  let a = UpgradePipe::new(c)
  let b = UpgradePipe::new(c)
  let left : &@rt.Conn = UpgradeConn::{ input: a, output: b, }
  let right : &@rt.Conn = UpgradeConn::{ input: b, output: a, }
  d.run(() => {
    let writer = d.spawn(() => left.write(b"pending"))
    d.pause()
    writer.cancel()
    ignore(writer.wait())
    assert_true(b.bytes.is_empty())
    assert_eq(right.read(max_len=1024), None)
  })
}
