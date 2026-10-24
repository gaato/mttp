///|
async test "nested: core test runs an old-runtime loop synchronously" {
  let flag = @ref.Ref(false)
  let t0 = @async.now()
  @async_coexist.run_old(async fn() { @old.sleep(50); flag.val = true })
  inspect(flag.val, content="true")
  inspect(@async.now() - t0 >= 50L, content="true")
}

///|
async test "blocking: a core timer cannot fire while the old loop runs" {
  let log : Array[String] = []
  @async.with_task_group(g => {
    g.spawn_bg(() => {
      @async.sleep(20)
      log.push("core timer fired at +\{@async.now()}")
    })
    g.spawn_bg(() => {
      @async.pause()
      let t0 = @async.now()
      @async_coexist.run_old(async fn() { @old.sleep(300) })
      log.push("old loop (300 ms) done after \{@async.now() - t0} ms")
    })
  })
  println(log.join("\n"))
  inspect(log[0].has_prefix("old loop"), content="true")
}

///|
async test "mixed: calling an old-runtime suspension from a core task" {
  let r = @async.with_timeout_opt(1000, () => @old.sleep(10))
  println("old sleep inside core task returned: \{r is Some(_)}")
}
