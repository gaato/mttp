///|
/// Proves the experimental opt-in in moon.pkg: core/async links and its event
/// loop runs a test on every supported target.
async test "core/async runs a task" {
  @async.sleep(1)
  inspect(1 + 1, content="2")
}
