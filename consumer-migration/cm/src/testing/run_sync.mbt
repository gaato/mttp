///|
fn run_async(f : async () -> Unit noraise + nocancel) = "%async.run"

///|
async fn[X] capture_cancellation(
  f : async () -> X,
  handler~ : async () -> X nocancel,
) -> X nocancel = "%async.capture_cancellation"

///|
pub(all) suberror RunSyncError {
  Suspended
  Cancelled
}

///|
/// Runs `f` to completion without an async runtime. Works only when nothing
/// in `f` waits on a real event source (stub backends, `FakeClock`); a
/// computation that suspends is refused with `Suspended`, never hung.
pub fn[X] run_sync(f : async () -> X) -> X raise {
  let mut result : Result[X, Error]? = None
  run_async(async fn() noraise + nocancel {
    let r : Result[X, Error] = try {
      Ok(capture_cancellation(f, handler=async fn() nocancel { raise Cancelled }))
    } catch {
      e => Err(e)
    }
    result = Some(r)
  })
  match result {
    Some(Ok(x)) => x
    Some(Err(e)) => raise e
    None => raise Suspended
  }
}
