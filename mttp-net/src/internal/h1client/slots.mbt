///|
pub(all) struct Ticket {
  id : Int64
  origin : String
  mut state : @control.TicketState
  cond : &@connection.Signal
}

///|
pub(all) struct Slots {
  coordination : &@connection.Coordination
  mut control : @control.SlotState
  tickets : Map[Int64, Ticket]
  mut next_id : Int64
}

///|
pub fn Slots::new(
  coordination~ : &@connection.Coordination,
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
  for notification in change.notifications {
    let (id, state) = notification
    if self.tickets.get(id) is Some(ticket) {
      ticket.state = state
      self.tickets.remove(id)
      ticket.cond.notify()
    }
  }
}

///|
pub fn Slots::fits(self : Slots, origin : String) -> Bool {
  self.control.fits(origin)
}

///|
pub fn Slots::waiting(self : Slots) -> Array[Ticket] {
  self.control.waiting.iter().map(ticket => self.tickets[ticket.id]).collect()
}

///|
pub fn Slots::enqueue(self : Slots, origin : String) -> Ticket {
  self.next_id += 1L
  let ticket : Ticket = {
    id: self.next_id,
    origin,
    state: Waiting,
    cond: self.coordination.signal(),
  }
  self.tickets[ticket.id] = ticket
  self.apply(self.control.acquire(ticket.id, origin))
  ticket
}

///|
pub fn Slots::take(self : Slots, origin : String) -> Unit {
  ignore(self.enqueue(origin))
}

///|
pub fn Slots::release(self : Slots, origin : String) -> Unit {
  self.apply(self.control.release(origin))
}

///|
pub fn Slots::abandon(self : Slots, ticket : Ticket) -> Unit {
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
pub fn Slots::refuse_waiting(self : Slots) -> Unit {
  self.apply(self.control.stop())
}

///|
pub async fn Ticket::wait(self : Ticket) -> Unit raise @model.TransportError {
  while self.state is Waiting {
    self.cond.wait()
  }
  if self.state is Refused {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="transport closed",
    )
  }
}

///|
pub async fn Slots::acquire(
  self : Slots,
  origin : String,
  timer : PhaseTimer,
) -> Unit raise @model.TransportError {
  let ticket = self.enqueue(origin)
  errdefer self.abandon(ticket)
  if !(ticket.state is Granted) {
    timer.run(Pool, () => ticket.wait())
  }
}
