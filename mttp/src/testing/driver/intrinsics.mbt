// The only file in gaato/mttp that names the compiler's `%async` intrinsics
// (scripts/test_layout.mbtx enforces this). They are undocumented compiler
// builtins, identical in moonbitlang/async 0.22.5 and core main; a toolchain
// that changes them breaks this file and nothing else. It is a library file,
// not a test file, so tests in other packages drive async code through
// `Driver` without linking an async runtime.

///|
/// Starts `f` as a coroutine and returns when it first suspends or finishes.
fn run_coroutine(f : async () -> Unit noraise + nocancel) = "%async.run"

///|
/// Suspends the calling coroutine; `register` receives the continuation that
/// resumes it with a value.
async fn[T] suspend_coroutine(
  register : ((T) -> Unit) -> Unit,
) -> T noraise + nocancel = "%async.suspend"

///|
/// Raises the compiler-builtin cancellation signal. It unwinds like an error,
/// running `defer` and `errdefer`, but no `try ... catch` can intercept it.
/// A gate built on `Driver::park_check_cancel` calls it after it has removed
/// a cancelled waiter from its queue.
pub async fn[X] raise_cancellation() -> X noraise = "%async.raise_cancellation_signal"

///|
/// Runs `f`; if it finishes by cancellation, runs `handler` instead and
/// returns its value.
async fn[X] capture_cancellation(
  f : async () -> X,
  handler~ : async () -> X nocancel,
) -> X nocancel = "%async.capture_cancellation"
