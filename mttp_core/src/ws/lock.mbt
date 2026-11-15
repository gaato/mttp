///|
/// Tickets are registered before entering Timer, preserving caller arrival order.
priv struct SendTicket {
  signal : &@rt.Signal
  mut granted : Bool
}

///|
priv struct SendLock {
  coordination : &@rt.Coordination
  queue : Array[SendTicket]
}

///|
fn SendLock::new(coordination : &@rt.Coordination) -> SendLock {
  { coordination, queue: [], }
}

///|
fn SendLock::enqueue(self : SendLock) -> SendTicket {
  let ticket = SendTicket::{
    signal: self.coordination.signal(),
    granted: self.queue.is_empty(),
  }
  self.queue.push(ticket)
  if ticket.granted {
    ticket.signal.notify()
  }
  ticket
}

///|
/// Removing either a waiting or an owning ticket transfers ownership at once.
fn SendLock::release(self : SendLock, ticket : SendTicket) -> Unit {
  self.queue.retain(other => !physical_equal(other, ticket))
  if ticket.granted && self.queue.get(0) is Some(next) {
    next.granted = true
    next.signal.notify()
  }
}
