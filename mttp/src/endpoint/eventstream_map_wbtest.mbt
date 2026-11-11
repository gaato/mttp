///|
test "EventStream::map keeps SSE fields and closes the source once" {
  let items = [
    SseItem::new(1, id="a", event="link", retry=500),
    SseItem::new(2),
  ]
  let i = Ref(0)
  let closes = Ref(0)
  let source : EventStream[Int32] = {
    pull: () => {
      if i.val < items.length() {
        i.val += 1
        Some(items[i.val - 1])
      } else {
        None
      }
    },
    close_: () => closes.val += 1,
    closed: false,
  }
  let rows = source.map(n => "<tr>\{n}</tr>")
  @driver.run_sync(() => {
    assert_eq(
      rows.next_item(),
      Some(SseItem::new("<tr>1</tr>", id="a", event="link", retry=500)),
    )
    assert_eq(rows.next_item(), Some(SseItem::new("<tr>2</tr>")))
    assert_eq(rows.next_item(), None)
  })
  rows.close()
  assert_eq(closes.val, 1)
}

///|
test "closing a mapped stream early closes its source" {
  let closes = Ref(0)
  let source = EventStream::from_pull(() => Some(1), () => closes.val += 1)
  let mapped = source.map(n => n + 1)
  @driver.run_sync(() => assert_eq(mapped.next(), Some(2)))
  mapped.close()
  mapped.close()
  assert_eq(closes.val, 1)
}
