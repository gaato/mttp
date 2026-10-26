///|
/// One scripted action for a body read. Waits use virtual milliseconds.
#non_exhaustive
pub(all) enum Step {
  Chunk(Bytes)
  Wait(Int32)
  Fail(@model.TransportError)
  End
}

///|
/// A deterministic body stream recording reads, closes and cancellation.
/// The script is copied, empty chunks are skipped, and EOF is permanent.
pub struct Feed {
  priv driver : @driver.Driver
  priv script : Array[Step]
  priv mut next : Int32
  priv mut reads : Int32
  priv mut closes : Int32
  priv mut cancelled : Int32
  priv mut closed : Bool
  priv mut ended : Bool
}

///|
/// Creates a scripted stream on a scheduler. A missing End is implicit EOF.
pub fn Feed::new(driver : @driver.Driver, script : Array[Step]) -> Feed {
  {
    driver,
    script: script.copy(),
    next: 0,
    reads: 0,
    closes: 0,
    cancelled: 0,
    closed: false,
    ended: false,
  }
}

///|
/// Creates a stream from chunks; empty chunks are omitted.
pub fn Feed::bytes(driver : @driver.Driver, chunks : Array[Bytes]) -> Feed {
  Feed::new(driver, chunks.map(bytes => Chunk(bytes)))
}

///|
/// Counts every read attempt, including reads after EOF or close.
pub fn Feed::reads(self : Feed) -> Int32 {
  self.reads
}

///|
/// Counts actual closes; repeated close calls keep this at one.
pub fn Feed::closes(self : Feed) -> Int32 {
  self.closes
}

///|
/// Counts interrupted reads. An injected Fail is not cancellation.
pub fn Feed::cancellations(self : Feed) -> Int32 {
  self.cancelled
}

///|
/// Reports whether resources have been released.
pub fn Feed::is_closed(self : Feed) -> Bool {
  self.closed
}

///|
/// Executes waits until a nonempty chunk, failure or EOF is reached.
pub impl @model.BodyStream for Feed with fn read_some(self) {
  self.reads += 1
  if self.closed || self.ended {
    return None
  }
  let mut normal_exit = false
  errdefer (if !normal_exit { self.cancelled += 1 })
  while self.next < self.script.length() {
    let step = self.script[self.next]
    self.next += 1
    match step {
      Wait(ms) => self.driver.sleep(ms)
      Chunk(bytes) if !bytes.is_empty() => {
        normal_exit = true
        return Some(bytes)
      }
      Chunk(_) => ()
      Fail(error) => {
        normal_exit = true
        self.ended = true
        raise error
      }
      End => break
    }
    if self.closed {
      break
    }
  }
  self.ended = true
  normal_exit = true
  None
}

///|
/// Releases the stream once and makes subsequent reads return EOF.
pub impl @model.BodyStream for Feed with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes += 1
  }
}

///|
/// Exposes body stream operations on the concrete test double.
pub extend Feed with @model.BodyStream::{read_some, close}
