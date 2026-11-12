// Admission of active client connections: a total cap and a per-origin cap,
// with a FIFO queue of waiting tickets. The h1client engine keeps the
// tickets' signals in its own table; this state holds ticket ids only and
// returns which tickets were granted or refused.

///|
/// A ticket waiting for a slot.
pub(all) struct Pending {
  id : Int64
  origin : String
}

///|
/// What a ticket was told.
pub(all) enum TicketState {
  /// Still queued.
  Waiting
  /// Holds a slot; its owner releases it.
  Granted
  /// Will never get a slot: abandoned, or the admission was stopped.
  Refused
}

///|
/// Slots in use per origin and the queue of tickets waiting for one.
pub(all) struct SlotState {
  /// The cap over all origins, or `None` for no cap; at least 1.
  max_total : Int32?
  /// The cap per origin, or `None` for no cap; at least 1.
  max_per_origin : Int32?
  /// Slots in use over all origins, the sum of `per_origin`.
  in_use : Int32
  /// Slots in use per origin; an origin with none has no entry.
  per_origin : @persistent.HashMap[String, Int32]
  /// Tickets waiting, in arrival order.
  waiting : @vector.Vector[Pending]
  /// Admission stopped: every acquire is refused.
  closed : Bool
}

///|
/// The state after a transition, and the tickets it decided, in the order
/// the engine must notify them.
pub(all) struct SlotChange {
  state : SlotState
  notifications : @vector.Vector[(Int64, TicketState)]
}

///|
/// No slot in use. A cap below 1 counts as 1; an unset cap never queues.
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
/// Whether one more slot for `origin` stays within both caps.
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
/// Ticket `id` asks for a slot for `origin`: granted at once when it fits,
/// queued otherwise, refused after `stop`.
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
/// Frees one slot of `origin` and grants it, and any other slot that now
/// fits, to the earliest waiters that fit, in queue order. Releasing an
/// origin that holds no slot changes nothing.
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
/// A waiting ticket gives up: it leaves the queue and frees nothing. A
/// granted ticket that gives up releases its slot with `release` instead.
pub fn SlotState::abandon(self : SlotState, id : Int64) -> SlotChange {
  {
    state: { ..self, waiting: self.waiting.filter(ticket => ticket.id != id), },
    notifications: @vector.Vector([(id, Refused)]),
  }
}

///|
/// Stops admission: every waiting ticket is refused, and so is every later
/// acquire. Slots in use stay until released.
pub fn SlotState::stop(self : SlotState) -> SlotChange {
  {
    state: { ..self, closed: true, waiting: @vector.Vector::new(), },
    notifications: self.waiting.map(ticket => (ticket.id, Refused)),
  }
}
