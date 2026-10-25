///|

///|
/// The slots in use, as `total origin=count ...`, and the origins of the
/// waiting tickets in queue order.
fn slots_label(slots : Slots) -> String {
  let origins = slots.per_origin.keys().collect()
  origins.sort()
  let counts = origins.map(origin => "\{origin}=\{slots.per_origin[origin]}")
  let waiting = slots.waiting.map(ticket => ticket.origin)
  let used = [slots.in_use.to_string(), ..counts].join(" ")
  "\{used} waiting [\{waiting.join(",")}]"
}

///|
fn ticket_state(ticket : Ticket) -> String {
  match ticket.state {
    Waiting => "waiting"
    Granted => "granted"
    Refused => "refused"
  }
}

///|
test "slots go to the earliest waiter they fit" {
  let slots = Slots::new(max_total=2, max_per_origin=1)
  let a = slots.enqueue("a")
  let b = slots.enqueue("b")
  let a2 = slots.enqueue("a") // `a` is at its cap and the total is full
  let c = slots.enqueue("c") // the total is full
  let b2 = slots.enqueue("b")
  assert_eq(slots_label(slots), "2 a=1 b=1 waiting [a,c,b]")
  assert_eq([a, b, a2, c, b2].map(ticket_state), [
    "granted", "granted", "waiting", "waiting", "waiting",
  ])
  // Freeing `b` frees one of the total: `a2` still does not fit, `c` is
  // earlier than `b2`.
  slots.release(b.origin)
  assert_eq(slots_label(slots), "2 a=1 c=1 waiting [a,b]")
  assert_eq(ticket_state(c), "granted")
  slots.release(a.origin)
  assert_eq(slots_label(slots), "2 a=1 c=1 waiting [b]")
  assert_eq(ticket_state(a2), "granted")
  // A waiter that gives up leaves the queue and frees nothing.
  slots.abandon(b2)
  assert_eq(slots_label(slots), "2 a=1 c=1 waiting []")
  // A granted ticket given up frees its slot.
  slots.abandon(a2)
  slots.release(c.origin)
  assert_eq(slots_label(slots), "0 waiting []")
}

///|
test "unset caps never queue and caps below 1 count as 1" {
  let open = Slots::new()
  for _ in 0..<100 {
    assert_eq(ticket_state(open.enqueue("a")), "granted")
  }
  assert_eq(open.in_use, 100)
  let one = Slots::new(max_total=0, max_per_origin=-3)
  assert_eq(ticket_state(one.enqueue("a")), "granted")
  assert_eq(ticket_state(one.enqueue("b")), "waiting")
  assert_eq(ticket_state(one.enqueue("a")), "waiting")
  one.refuse_waiting()
  assert_eq(slots_label(one), "1 a=1 waiting []")
}

///|
test "slot bookkeeping holds its invariants under random use" {
  let origins = ["a", "b", "c"]
  for seed in 0..<8 {
    let rand = @random.Rand::chacha8(seed=Bytes::make(32, seed.to_byte()))
    let max_total = 1 + rand.int(limit=4)
    let max_per_origin = 1 + rand.int(limit=3)
    let slots = Slots::new(max_total~, max_per_origin~)
    // Tickets still waiting, in arrival order, and those holding a slot.
    let pending : Array[Ticket] = []
    let holding : Array[Ticket] = []
    for _ in 0..<400 {
      match rand.int(limit=3) {
        0 => {
          let ticket = slots.enqueue(origins[rand.int(limit=3)])
          if ticket.state is Granted {
            holding.push(ticket)
          } else {
            pending.push(ticket)
          }
        }
        1 if !holding.is_empty() => {
          let ticket = holding.remove(rand.int(limit=holding.length()))
          slots.release(ticket.origin)
        }
        _ if !pending.is_empty() =>
          slots.abandon(pending[rand.int(limit=pending.length())])
        _ => ()
      }
      // Move the grants a release made to the holders; a grant never passes
      // an earlier waiter of the same origin.
      let still : Array[Ticket] = []
      for ticket in pending {
        match ticket.state {
          Granted => {
            assert_false(still.any(t => t.origin == ticket.origin))
            holding.push(ticket)
          }
          Waiting => still.push(ticket)
          Refused => ()
        }
      }
      pending.clear()
      pending.append(still)
      // The queue is exactly the waiting tickets, in arrival order.
      assert_true(
        slots.waiting.length() == pending.length() &&
        slots.waiting
        .iter()
        .zip(pending.iter())
        .all(pair => physical_equal(pair.0, pair.1)),
      )
      assert_eq(slots.in_use, holding.length())
      assert_true(slots.in_use <= max_total)
      for origin in origins {
        let held = holding.filter(t => t.origin == origin).length()
        assert_eq(slots.per_origin.get(origin).unwrap_or(0), held)
        assert_true(held <= max_per_origin)
      }
      // No waiter is left behind a slot it fits.
      assert_true(slots.waiting.iter().all(t => !slots.fits(t.origin)))
    }
  }
}
