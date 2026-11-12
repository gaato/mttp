///|
/// A request waiting for, or holding, a connection slot.
priv struct Ticket {
  id : Int64
  origin : String
  mut state : @control.TicketState
  signal : &@rt.Signal
}

///|
/// Admission of active exchanges. The persistent control state holds
/// ticket ids only; the tickets and their signals live in `tickets`, and a
/// transition's state is committed before its tickets are woken.
priv struct Slots {
  coordination : &@rt.Coordination
  mut control : @control.SlotState
  tickets : Map[Int64, Ticket]
  mut next_id : Int64
}

///|
fn Slots::new(
  coordination~ : &@rt.Coordination,
  max_total? : Int32,
  max_per_origin? : Int32,
) -> Slots {
  {
    coordination,
    control: @control.SlotState::new(max_total?, max_per_origin?),
    tickets: Map([]),
    next_id: 0L,
  }
}

///|
fn Slots::apply(self : Slots, change : @control.SlotChange) -> Unit {
  self.control = change.state
  let woken = []
  for notification in change.notifications {
    let (id, state) = notification
    if self.tickets.get(id) is Some(ticket) {
      ticket.state = state
      self.tickets.remove(id)
      woken.push(ticket)
    }
  }
  for ticket in woken {
    ticket.signal.notify()
  }
}

///|
/// A new ticket for `origin`, granted at once when a slot fits.
fn Slots::enqueue(self : Slots, origin : String) -> Ticket {
  self.next_id += 1L
  let ticket : Ticket = {
    id: self.next_id,
    origin,
    state: Waiting,
    signal: self.coordination.signal(),
  }
  self.tickets[ticket.id] = ticket
  self.apply(self.control.acquire(ticket.id, origin))
  ticket
}

///|
/// Frees a slot of `origin` and grants it to the earliest waiter it fits.
fn Slots::release(self : Slots, origin : String) -> Unit {
  self.apply(self.control.release(origin))
}

///|
/// Gives a ticket up: a granted one frees its slot, a waiting one leaves
/// the queue.
fn Slots::abandon(self : Slots, ticket : Ticket) -> Unit {
  match ticket.state {
    Granted => {
      ticket.state = Refused
      self.release(ticket.origin)
    }
    Waiting => self.apply(self.control.abandon(ticket.id))
    Refused => ()
  }
}

///|
/// Refuses every waiting ticket and every later one.
fn Slots::stop(self : Slots) -> Unit {
  self.apply(self.control.stop())
}

///|
/// Waits until the ticket is granted; a refusal raises `Closed` in phase
/// Pool.
async fn Ticket::wait(self : Ticket) -> Unit raise @mttp_core.TransportError {
  while self.state is Waiting {
    self.signal.wait()
  }
  if self.state is Refused {
    raise closed()
  }
}

///|
/// Takes a slot for `origin`, waiting under the Pool limit when none fits.
/// Giving up (a timeout, a refusal, cancellation) leaves no slot held and
/// no ticket queued.
async fn Slots::acquire(
  self : Slots,
  origin : String,
  timer : PhaseTimer,
) -> Unit raise @mttp_core.TransportError {
  let ticket = self.enqueue(origin)
  errdefer self.abandon(ticket)
  if ticket.state is Refused {
    raise closed()
  }
  if !(ticket.state is Granted) {
    timer.run(Pool, () => ticket.wait())
  }
}
