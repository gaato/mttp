///|
/// Whether `error`, raised by a read of a TLS session, says that the peer
/// closed the connection beneath without close_notify. MoonBit 0.10.20's
/// core/async cannot tell: its TLS client returns EOF then. Later
/// toolchains raise `@io.UnexpectedEof`, which 0.10.20 does not define, so
/// compat/core_async_next keeps their version of this file, and the canary
/// copies it over this one (.github/workflows/canary.yml).
fn incomplete_close(_ : Error) -> Bool {
  false
}
