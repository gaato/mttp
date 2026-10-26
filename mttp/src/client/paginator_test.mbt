///|
test "collect and each propagate expected failures without converting them to effects" {
  @driver.run_sync(() => {
    let calls = Ref(0)
    let p : @client.Paginator[Int32, String] = @client.Paginator::new(() => {
      calls.val += 1
      match calls.val {
        1 | 2 => Err("fetch")
        3 => Ok(Some([1, 2]))
        _ => Ok(None)
      }
    })
    assert_eq(p.collect(max=2), Err("fetch"))
    assert_eq(p.each(_ => fail("failed fetch delivered an item")), Err("fetch"))
    let seen = []
    assert_eq(
      p.each(item => {
        seen.push(item)
        Err("consumer")
      }),
      Err("consumer"),
    )
    assert_eq(seen, [1])
    assert_eq(p.next_page(), Ok(None))
  })
}

///|
test "Paginator follows cursors and stays finished" {
  @driver.run_sync(() => {
    let seen = []
    let p : @client.Paginator[Int32, String] = @client.Paginator::with_cursor(cursor => {
      seen.push(cursor)
      Ok(
        match cursor {
          None => @client.Page::{ items: [0], next: Some("second"), }
          Some("second") => @client.Page::{ items: [1, 2], next: None, }
          _ => abort("unexpected cursor")
        },
      )
    })
    assert_eq(p.next_page(), Ok(Some([0])))
    assert_eq(p.next_page(), Ok(Some([1, 2])))
    assert_eq(p.next_page(), Ok(None))
    assert_eq(p.next_page(), Ok(None))
    assert_eq(seen, [None, Some("second")])
  })
}

///|
test "Paginator empty pages end even with a next cursor" {
  @driver.run_sync(() => {
    let calls = Ref(0)
    let p : @client.Paginator[Int32, String] = @client.Paginator::with_cursor(_ => {
      calls.val += 1
      Ok(@client.Page::{ items: [], next: Some("next"), })
    })
    assert_eq(p.next_page(), Ok(None))
    assert_eq(p.next_page(), Ok(None))
    assert_eq(calls.val, 1)
  })
}

///|
test "Paginator collect keeps unused items and zero does not fetch" {
  @driver.run_sync(() => {
    let seen = []
    let p : @client.Paginator[Int32, String] = @client.Paginator::with_cursor(cursor => {
      seen.push(cursor)
      Ok(
        if cursor is None {
          @client.Page::{ items: [1, 2, 3], next: Some("next"), }
        } else {
          @client.Page::{ items: [4], next: None, }
        },
      )
    })
    assert_eq(p.collect(max=0), Ok([]))
    assert_eq(seen, [])
    assert_eq(p.collect(max=2), Ok([1, 2]))
    assert_eq(p.next_page(), Ok(Some([3])))
    assert_eq(seen, [None])
    assert_eq(p.next_page(), Ok(Some([4])))
    assert_eq(p.next_page(), Ok(None))
    let items = []
    let q : @client.Paginator[Int32, String] = @client.Paginator::new(() => {
      if items.is_empty() {
        items.push(1)
        Ok(Some([7, 8]))
      } else {
        Ok(None)
      }
    })
    let visited = []
    assert_eq(
      q.each(item => {
        visited.push(item)
        Ok(())
      }),
      Ok(()),
    )
    assert_eq(visited, [7, 8])
  })
}

///|
test "Paginator failures leave cursor unchanged for expected and transport errors" {
  @driver.run_sync(() => {
    let seen = []
    let p : @client.Paginator[Int32, String] = @client.Paginator::with_cursor(cursor => {
      seen.push(cursor)
      match seen.length() {
        1 => Ok(@client.Page::{ items: [1], next: Some("next"), })
        2 => Err("expected")
        3 =>
          raise @model.TransportError(
            kind=Network,
            phase=Head,
            detail="offline",
          )
        _ => Ok(@client.Page::{ items: [2], next: None, })
      }
    })
    assert_eq(p.next_page(), Ok(Some([1])))
    assert_eq(p.next_page(), Err("expected"))
    try {
      let _ = p.next_page()
      fail("transport error lost")
    } catch {
      @model.TransportError(kind=Network, ..) => ()
      other => raise other
    }
    assert_eq(p.collect(max=10), Ok([2]))
    assert_eq(seen, [None, Some("next"), Some("next"), Some("next")])
  })
}
