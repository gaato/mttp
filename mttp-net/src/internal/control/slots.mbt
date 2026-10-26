///|
pub(all) struct Pending {
  id : Int64
  origin : String
}

///|
pub(all) enum TicketState {
  Waiting
  Granted
  Refused
}

///|
pub(all) struct SlotState {
  max_total : Int32?
  max_per_origin : Int32?
  in_use : Int32
  per_origin : @persistent.HashMap[String, Int32]
  waiting : @vector.Vector[Pending]
  closed : Bool
}

///|
pub(all) struct SlotChange {
  state : SlotState
  notifications : @vector.Vector[(Int64, TicketState)]
}

///|
pub fn SlotState::new(max_total? : Int32, max_per_origin? : Int32) -> SlotState {
  {
    max_total: max_total.map(n => n.max(1)),
    max_per_origin: max_per_origin.map(n => n.max(1)),
    in_use: 0,
    per_origin: @persistent.HashMap::new(),
    waiting: @vector.Vector::new(),
    closed: false,
  }
}

///|
pub fn SlotState::fits(self : SlotState, origin : String) -> Bool {
  self.max_total.map(n => self.in_use < n).unwrap_or(true) &&
  self.max_per_origin
  .map(n => self.per_origin.get(origin).unwrap_or(0) < n)
  .unwrap_or(true)
}

///|
fn SlotState::take(self : SlotState, origin : String) -> SlotState {
  {
    ..self,
    in_use: self.in_use + 1,
    per_origin: self.per_origin.add(
      origin,
      self.per_origin.get(origin).unwrap_or(0) + 1,
    ),
  }
}

///|
pub fn SlotState::acquire(
  self : SlotState,
  id : Int64,
  origin : String,
) -> SlotChange {
  if self.closed {
    return { state: self, notifications: @vector.Vector([(id, Refused)]), }
  }
  if self.fits(origin) {
    {
      state: self.take(origin),
      notifications: @vector.Vector([(id, Granted)]),
    }
  } else {
    {
      state: { ..self, waiting: self.waiting.push({ id, origin, }), },
      notifications: @vector.Vector::new(),
    }
  }
}

///|
pub fn SlotState::release(self : SlotState, origin : String) -> SlotChange {
  let count = self.per_origin.get(origin).unwrap_or(0)
  if count <= 0 {
    return { state: self, notifications: @vector.Vector::new(), }
  }
  let counts = if count == 1 {
    self.per_origin.remove(origin)
  } else {
    self.per_origin.add(origin, count - 1)
  }
  let mut state = { ..self, in_use: self.in_use - 1, per_origin: counts, }
  let remaining = []
  let notifications = []
  for ticket in self.waiting {
    if !state.closed && state.fits(ticket.origin) {
      state = state.take(ticket.origin)
      notifications.push((ticket.id, Granted))
    } else {
      remaining.push(ticket)
    }
  }
  {
    state: { ..state, waiting: @vector.Vector(remaining[:]), },
    notifications: @vector.Vector(notifications[:]),
  }
}

///|
pub fn SlotState::abandon(self : SlotState, id : Int64) -> SlotChange {
  {
    state: { ..self, waiting: self.waiting.filter(ticket => ticket.id != id), },
    notifications: @vector.Vector([(id, Refused)]),
  }
}

///|
pub fn SlotState::stop(self : SlotState) -> SlotChange {
  {
    state: { ..self, closed: true, waiting: @vector.Vector::new(), },
    notifications: self.waiting.map(ticket => (ticket.id, Refused)),
  }
}
