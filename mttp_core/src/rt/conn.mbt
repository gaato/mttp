// The connection ports. A connection engine reads and writes through `Conn`,
// dials through `Dialer` and runs its reader and its watcher of the peer
// through `Coordination`, so the same engine runs over sockets, TLS, a
// CONNECT tunnel or an in-memory pair. CONTRACT.md (Connections and
// coordination) states what each side may rely on.

///|
/// An owned, full-duplex byte connection.
///
/// One read and one write may run at the same time. `rt.Conn` has no
/// write-half shutdown, because the runtime offers none for sockets or TLS.
pub(open) trait Conn {
  /// Reads a nonempty chunk of at most `max_len` bytes, or `None` at EOF.
  /// EOF is permanent and ends only the read half: writes may continue.
  /// A cancelled read finishes its cleanup before the next read begins.
  async fn read(Self, max_len~ : Int32) -> Bytes? raise @mttp_core.TransportError
  /// Writes all of `bytes`, or raises. A write after `close` raises.
  /// Raising `Closed` promises that none of `bytes` was sent: the
  /// connection was already closed, by this end or by the peer (a TLS
  /// session the peer shut down refuses writes). Any other failure may come
  /// after part of `bytes` was sent.
  async fn write(Self, Bytes) -> Unit raise @mttp_core.TransportError
  /// Closes both halves and wakes pending operations. Idempotent.
  fn close(Self) -> Unit
}

///|
/// Opens connections and upgrades them to TLS, without naming a runtime or
/// TLS type.
pub(open) trait Dialer {
  /// Connects to `host` on `port`.
  async fn connect(Self, host~ : String, port~ : Int32) -> &Conn raise @mttp_core.TransportError
  /// Starts a TLS client session for `host` over `conn`, which may itself be
  /// a tunnel. A successful upgrade owns `conn`; after a failed one the
  /// caller still owns `conn` and closes it.
  async fn start_tls(Self, &Conn, host~ : String) -> &Conn raise @mttp_core.TransportError
}

///|
/// A sticky one-shot notification.
pub(open) trait Signal {
  /// Waits until `notify` has been called, returning at once if it already
  /// was. A cancelled waiter unregisters before it unwinds.
  async fn wait(Self) -> Unit noraise
  /// Wakes every waiter, now and later. Repeated calls are harmless.
  fn notify(Self) -> Unit
}

///|
/// The structured concurrency a connection engine needs.
pub(open) trait Coordination {
  /// A new signal on this coordination's scheduler.
  fn signal(Self) -> &Signal
  /// Runs `primary` and `monitor` as children and returns when both have
  /// finished their cleanup. The monitor completing normally lets `primary`
  /// continue; the monitor failing cancels `primary` and raises the
  /// monitor's error; `primary` finishing (normally or not) cancels the
  /// monitor. The first outcome delivered wins. Cancelling the caller
  /// cancels both and propagates once both have unwound.
  async fn supervise(
    Self,
    primary~ : async () -> Unit raise @mttp_core.TransportError,
    monitor~ : async () -> Unit raise @mttp_core.TransportError,
  ) -> Unit raise @mttp_core.TransportError
}
