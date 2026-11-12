///|
/// How the sending side ended a channel.
priv enum ChannelEnd {
  Closed
  Failed(Error)
}

///|
/// The state a channel's sender and its stream share. Waiting uses sticky
/// one-shot signals from the coordination. The reader waits on a new signal;
/// senders that must wait share the pending one (making one if none is).
/// The other side notifies and drops the signal after each change, so every
/// wait after a change sees a fresh one.
priv struct Channel[T] {
  coordination : &@rt.Coordination
  capacity : Int32
  queue : @queue.Queue[T]
  mut end : ChannelEnd?
  mut reader_closed : Bool
  mut readable : &@rt.Signal?
  mut writable : &@rt.Signal?
}

///|
fn[T] Channel::wake_reader(self : Channel[T]) -> Unit {
  if self.readable is Some(signal) {
    self.readable = None
    signal.notify()
  }
}

///|
fn[T] Channel::wake_senders(self : Channel[T]) -> Unit {
  if self.writable is Some(signal) {
    self.writable = None
    signal.notify()
  }
}

///|
async fn[T] Channel::pull(self : Channel[T]) -> T? {
  for ;; {
    if self.reader_closed {
      return None
    }
    if self.queue.pop() is Some(value) {
      self.wake_senders()
      return Some(value)
    }
    match self.end {
      Some(Closed) => return None
      Some(Failed(error)) => raise error
      None => ()
    }
    // The stream has one reader, and a reader whose wait is cancelled closes
    // the stream, so no earlier reader's signal can still be pending here.
    let signal = self.coordination.signal()
    self.readable = Some(signal)
    signal.wait()
  }
}

///|
fn[T] Channel::close_reader(self : Channel[T]) -> Unit {
  self.reader_closed = true
  self.queue.clear()
  self.wake_senders()
  self.wake_reader()
}

///|
/// The sending side of `EventStream::channel`.
pub struct EventSender[T] {
  priv channel : Channel[T]
}

///|
/// Creates a bounded channel: values sent through the `EventSender` are read,
/// in the order they were sent, from the `EventStream`; when several tasks
/// send through one sender, each task's values keep their order. It bridges
/// a producer that pushes, such as an SDK's streaming callback, to a stream
/// that a handler returns for `sse_out`.
///
/// At most `capacity` values wait in the channel; `send` waits while it is
/// full, so a slow reader slows the producer down. A `capacity` below 1 is
/// taken as 1, as the dispatch limits clamp their bounds. `coordination`
/// provides the waiting: `RuntimeCoordination::new()` from
/// `gaato/mttp/runtime` in an app, `@sim.SimCoordination` in a test.
///
/// Closing the stream (its reader stops, or the client disconnects while
/// `sse_out` streams it) drops the queued values and makes every `send`
/// return `false`, including one that is waiting, so the producer can stop.
/// Values read from the stream carry no SSE fields of their own, as with
/// `from_pull`.
///
/// ```mbt check
/// test {
///   @driver.run_sync(() => {
///     let coordination = @sim.SimCoordination::new(@driver.current())
///     let (sender, stream) = @endpoint.EventStream::channel(coordination~)
///     assert_true(sender.send(1))
///     assert_true(sender.send(2))
///     sender.close()
///     let read = []
///     stream.each(n => read.push(n))
///     assert_eq(read, [1, 2])
///   })
/// }
/// ```
pub fn[T] EventStream::channel(
  coordination~ : &@rt.Coordination,
  capacity~ : Int32 = 16,
) -> (EventSender[T], EventStream[T]) {
  let channel = {
    coordination,
    capacity: capacity.max(1),
    queue: @queue.Queue([]),
    end: None,
    reader_closed: false,
    readable: None,
    writable: None,
  }
  (
    { channel, },
    EventStream::from_pull(() => channel.pull(), () => channel.close_reader()),
  )
}

///|
/// Queues `value` for the stream, waiting while `capacity` values are queued.
/// Returns `true` once the value is queued, and `false` without queueing it
/// when the stream has been closed by its reader or this sender has already
/// ended it; a send waiting for room returns `false` as soon as the reader
/// closes. After `false`, stop producing: every later send returns `false`
/// at once.
pub async fn[T] EventSender::send(
  self : EventSender[T],
  value : T,
) -> Bool noraise {
  let channel = self.channel
  for ;; {
    if channel.reader_closed || channel.end is Some(_) {
      return false
    }
    if channel.queue.length() < channel.capacity {
      channel.queue.push(value)
      channel.wake_reader()
      return true
    }
    let signal = match channel.writable {
      Some(signal) => signal
      None => {
        let signal = channel.coordination.signal()
        channel.writable = Some(signal)
        signal
      }
    }
    signal.wait()
  }
}

///|
/// Ends the stream: its reader reads the queued values, then the end
/// (`None`). Later sends return `false`. Only the first `close` or `fail`
/// counts.
pub fn[T] EventSender::close(self : EventSender[T]) -> Unit {
  self.finish(Closed)
}

///|
/// Ends the stream with `error`: its reader reads the queued values, then the
/// pull raises `error`. Use it when the producer failed, so the stream does
/// not look complete: `sse_out` then ends the response with a transport
/// failure instead of a clean end, and a client sees an error, not a
/// finished stream. Later sends return `false`. Only the first `close` or
/// `fail` counts.
pub fn[T] EventSender::fail(self : EventSender[T], error : Error) -> Unit {
  self.finish(Failed(error))
}

///|
fn[T] EventSender::finish(self : EventSender[T], end : ChannelEnd) -> Unit {
  let channel = self.channel
  if channel.end is None {
    channel.end = Some(end)
  }
  channel.wake_reader()
  channel.wake_senders()
}
