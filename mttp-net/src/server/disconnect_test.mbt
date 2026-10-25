///|
async test "peer read-side disconnect cancels a suspended handler" {
  let entered = Ref(false)
  let cleaned = Ref(false)
  let wake = @cond_var.Cond()
  with_server(
    _ => {
      defer {
        cleaned.val = true
        wake.broadcast()
      }
      entered.val = true
      wake.broadcast()
      @async.sleep(10000)
      @model.Response::new(200)
    },
    address => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      while !entered.val {
        wake.wait()
      }
      tcp.close()
      @async.with_timeout(1000, () => {
        while !cleaned.val {
          wake.wait()
        }
      })
    },
  )
  assert_true(cleaned.val)
}
