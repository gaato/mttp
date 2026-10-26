///|
// The public socket facade is unchanged by the refactor, so this exact
// workload can run against both the baseline and candidate workspace.
async fn sample(chunk_bytes : Int32) -> Double {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_task_group(group => {
    let remote = group.spawn(() => {
      let (tcp, _) = listener.accept()
      defer tcp.close()
      while tcp.read_until("\r\n\r\n") is Some(_) {
        let reply = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npong"
        for offset = 0; offset < reply.length(); {
          let end = (offset + chunk_bytes).min(reply.length())
          tcp.write(reply[offset:end])
          continue end
        }
      }
    })
    let backend = @backend.H1Backend::new(trust_env=false)
    defer backend.close()
    let request = @model.Request::get(
      "http://127.0.0.1:\{listener.addr.port()}/",
    )
    let exchange : async () -> Unit = () => {
      let response = backend.send(request, @client.RequestOptions::default())
      defer response.close()
      assert_eq(@client.read_body(response.body, 10), b"pong")
    }
    for _ in 0..<32 {
      exchange()
    }
    let start = @bench.monotonic_clock_start()
    for _ in 0..<500 {
      exchange()
    }
    let us = @bench.monotonic_clock_end(start) / 500.0
    backend.close()
    remote.wait()
    us
  })
}

///|
async fn main {
  for chunk_bytes in [65536, 1] {
    let samples = []
    for _ in 0..<3 {
      samples.push(sample(chunk_bytes))
    }
    samples.sort()
    println("loopback chunk=\{chunk_bytes} median_us_per_request=\{samples[1]}")
  }
}
