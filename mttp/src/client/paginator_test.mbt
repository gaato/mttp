///|
test "Paginator starts with None follows the cursor and stays finished" {
  @driver.run_sync(() => {
    let cursors : Array[String?] = []
    let paginator = @client.Paginator::with_cursor(cursor => {
      cursors.push(cursor)
      match cursor {
        None => @client.Page::{ items: [0], next: Some("second"), }
        Some("second") => @client.Page::{ items: [1, 2], next: None, }
        _ => raise @client.InvalidRequest(message="unexpected cursor")
      }
    })
    assert_eq(paginator.next_page(), Some([0]))
    assert_eq(paginator.next_page(), Some([1, 2]))
    assert_eq(paginator.next_page(), None)
    assert_eq(paginator.next_page(), None)
    assert_eq(cursors, [None, Some("second")])
  })
}

///|
test "Paginator ends at an empty page even when a cursor follows" {
  @driver.run_sync(() => {
    let cursors : Array[String?] = []
    let paginator : @client.Paginator[Int32, @client.InvalidRequest] = @client.Paginator::with_cursor(cursor => {
        cursors.push(cursor)
        match cursor {
          None => @client.Page::{ items: [], next: Some("second"), }
          _ => raise @client.InvalidRequest(message="unexpected cursor")
        }
      },
    )
    assert_eq(paginator.next_page(), None)
    assert_eq(paginator.next_page(), None)
    assert_eq(cursors, [None])
  })
}

///|
test "Paginator each visits every item and collect keeps the unused rest" {
  @driver.run_sync(() => {
    let each_paginator = @client.Paginator::with_cursor(cursor => {
      match cursor {
        None => @client.Page::{ items: [1, 2], next: Some("next"), }
        Some("next") => @client.Page::{ items: [3], next: None, }
        _ => raise @client.InvalidRequest(message="unexpected cursor")
      }
    })
    let seen = []
    each_paginator.each(item => seen.push(item))
    assert_eq(seen, [1, 2, 3])

    let fetched : Array[String?] = []
    let collect_paginator = @client.Paginator::with_cursor(cursor => {
      fetched.push(cursor)
      match cursor {
        None => @client.Page::{ items: [1, 2, 3], next: Some("next"), }
        Some("next") => @client.Page::{ items: [4], next: None, }
        _ => raise @client.InvalidRequest(message="unexpected cursor")
      }
    })
    assert_eq(collect_paginator.collect(max=2), [1, 2])
    assert_eq(fetched, [None])
    // The unused rest of the page comes back before the next fetch.
    assert_eq(collect_paginator.next_page(), Some([3]))
    assert_eq(fetched, [None])
    assert_eq(collect_paginator.next_page(), Some([4]))
    assert_eq(collect_paginator.next_page(), None)
    let zero : @client.Paginator[Int32, @client.InvalidRequest] = @client.Paginator::with_cursor(_ => @client.Page::{
        items: [1],
        next: None,
      },
    )
    assert_eq(zero.collect(max=0), [])
  })
}

///|
test "Paginator failed fetch retries the same cursor" {
  @driver.run_sync(() => {
    let cursors : Array[String?] = []
    let paginator = @client.Paginator::with_cursor(cursor => {
      cursors.push(cursor)
      if cursors.length() == 1 {
        raise @client.InvalidRequest(message="temporary")
      }
      @client.Page::{ items: [7], next: None, }
    })
    try paginator.next_page() catch {
      @client.InvalidRequest(message="temporary") => ()
      _ => fail("expected fetch error")
    } noraise {
      _ => fail("expected fetch error")
    }
    assert_eq(paginator.next_page(), Some([7]))
    assert_eq(cursors, [None, None])
  })
}

///|
test "Paginator::new lets the fetch own any cursor and stops at None" {
  @driver.run_sync(() => {
    let calls = Ref(0)
    let paginator : @client.Paginator[Int32, @client.InvalidRequest] = @client.Paginator::new(() => {
        calls.val += 1
        match calls.val {
          1 => Some([1, 2])
          2 => Some([3])
          _ => None
        }
      },
    )
    assert_eq(paginator.collect(max=10), [1, 2, 3])
    assert_eq(calls.val, 3)
    assert_eq(paginator.next_page(), None)
    assert_eq(calls.val, 3)
  })
}
