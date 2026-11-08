///|
/// One scripted action of a Feed read.
#non_exhaustive
pub(all) enum FeedStep {
  /// Bytes to return; empty ones are skipped.
  Chunk(Bytes)
  /// A virtual sleep of this many milliseconds on the Feed's Driver.
  Wait(Int32)
  /// A failure raised once; later reads return EOF.
  Fail(@http.TransportError)
  /// EOF; the steps after it are never played.
  End
}

///|
/// A scripted `BodyStream` on a Driver that counts reads, closes and
/// cancelled reads. EOF is permanent and a missing `End` is implicit.
pub struct Feed {
  priv driver : @driver.Driver
  priv script : Array[FeedStep]
  priv mut next : Int32
  priv mut reads : Int32
  priv mut closes : Int32
  priv mut cancelled : Int32
  priv mut closed : Bool
  priv mut ended : Bool
}

///|
/// Creates a stream that plays a copy of `script` on `driver`.
///
/// ```mbt check
/// test {
///   let d = @driver.Driver::new()
///   let feed = @sim.Feed::new(d, [Chunk(b"he"), Wait(10), Chunk(b"llo")])
///   let body = d.run(() => @http.read_bounded(feed, 16))
///   assert_eq(body, b"hello")
///   assert_eq(d.now(), 10L)
///   assert_eq(feed.closes(), 1)
/// }
/// ```
pub fn Feed::new(driver : @driver.Driver, script : Array[FeedStep]) -> Feed {
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
/// Creates a stream that returns `chunks` in order, skipping empty ones.
pub fn Feed::bytes(driver : @driver.Driver, chunks : Array[Bytes]) -> Feed {
  Feed::new(driver, chunks.map(bytes => Chunk(bytes)))
}

///|
/// How many reads were attempted, including those after EOF or close.
pub fn Feed::reads(self : Feed) -> Int32 {
  self.reads
}

///|
/// How many times the stream was closed: 0 or 1, however often `close` is
/// called.
pub fn Feed::closes(self : Feed) -> Int32 {
  self.closes
}

///|
/// How many reads were cancelled while waiting. A scripted `Fail` is not a
/// cancellation.
pub fn Feed::cancellations(self : Feed) -> Int32 {
  self.cancelled
}

///|
/// Whether the stream was closed.
pub fn Feed::is_closed(self : Feed) -> Bool {
  self.closed
}

///|
/// Plays the script up to the next nonempty chunk, failure or EOF. A close
/// during a wait ends the read with EOF.
pub impl @http.BodyStream for Feed with fn read_some(self) {
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
/// Closes the stream once; later reads return EOF.
pub impl @http.BodyStream for Feed with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes += 1
  }
}

///|
/// The stream operations as methods of the double.
pub extend Feed with @http.BodyStream::{read_some, close}
