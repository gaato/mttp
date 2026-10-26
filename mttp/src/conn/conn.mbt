///|
/// An owned, full-duplex byte connection. Reads are nonempty and bounded by
/// max_len; None is permanent read EOF and does not close the writable half.
/// One read and one write may run concurrently. Writes consume all bytes.
/// close is idempotent and wakes pending operations. Cancellation must unwind
/// an operation before another operation in the same direction may begin.
pub(open) trait Conn {
  async fn read(Self, max_len~ : Int32) -> Bytes? raise @model.TransportError
  async fn write(Self, Bytes) -> Unit raise @model.TransportError
  fn close(Self) -> Unit
}

///|
/// Creates connections and upgrades them without exposing a runtime or TLS
/// implementation type. A successful upgrade owns its input connection;
/// a failed upgrade leaves that input owned by its caller for cleanup.
pub(open) trait Dialer {
  async fn connect(Self, host~ : String, port~ : Int32) -> &Conn raise @model.TransportError
  async fn start_tls(Self, &Conn, host~ : String) -> &Conn raise @model.TransportError
}

///|
/// A one-shot notification. notify before wait is retained, repeated notify
/// is harmless, and a cancelled waiter unregisters before it unwinds.
pub(open) trait Signal {
  async fn wait(Self) -> Unit noraise
  fn notify(Self) -> Unit
}

///|
/// The two structured concurrency operations required by connection engines.
/// A monitor's normal completion leaves primary running. An ordinary monitor
/// failure interrupts primary. Completion of primary cancels the monitor.
/// Parent cancellation interrupts both; every exit waits for their cleanup.
/// Simultaneous outcomes follow delivery order, without replacing parent
/// cancellation with an ordinary error.
pub(open) trait Coordination {
  fn signal(Self) -> &Signal
  async fn supervise(
    Self,
    primary~ : async () -> Unit raise @model.TransportError,
    monitor~ : async () -> Unit raise @model.TransportError,
  ) -> Unit raise @model.TransportError
}
