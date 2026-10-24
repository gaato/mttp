///|
/// Runs an old-runtime (moonbitlang/async 0.22.5) computation to completion
/// on its own, nested event loop. Synchronous: blocks the caller's loop.
pub fn run_old(f : async () -> Unit) -> Unit {
  @old.run_async_main(f)
}
