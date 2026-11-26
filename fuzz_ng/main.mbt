// The seeds of each target, and a run of every target on each of its
// seeds: the gates' native build links and exercises all three entry
// points, and scripts/fuzz.mbtx takes the seeds from `main.exe seeds`
// (one `target hex` line each; core has no synchronous file writes).

///|
/// What a client session sends for `requests`, each with `body` when it
/// is not empty: the server target's seeds are real clients' bytes.
fn client_bytes(requests : Array[(String, Bytes)]) -> Bytes {
  let client = @h2.H2Session::client() catch { _ => abort("no client session") }
  defer client.free()
  let out = Buffer()
  for request in requests {
    let (meth, body) = request
    let id = client.submit_request(
      [
        (":method", meth),
        (":scheme", "https"),
        (":authority", "example.com"),
        (":path", "/"),
        ("user-agent", "fuzz"),
      ],
      body=!body.is_empty(),
    ) catch {
      _ => abort("no request")
    }
    if !body.is_empty() {
      client.push(id, body, end=true) catch {
        _ => abort("no body")
      }
    }
    out.write_bytes(client.output())
  }
  client.ping() catch {
    _ => ()
  }
  out.write_bytes(client.output())
  out.to_bytes()
}

///|
/// The seeds of each target.
fn seeds() -> Array[(String, Bytes)] {
  let out = []
  let transcripts = [
    client_bytes([("GET", b"")]),
    client_bytes([("POST", b"hello, server")]),
    client_bytes([("GET", b""), ("POST", Bytes::make(3000, b'x')), ("GET", b"")]),
  ]
  for transcript in transcripts {
    // Every mode, whole and in small pieces.
    for mode in [0x00, 0x05, 0x0a, 0x0f] {
      for piece in [255, 0, 6] {
        let seed = Buffer()
        seed.write_byte(mode.to_byte())
        seed.write_byte(piece.to_byte())
        seed.write_bytes(transcript)
        out.push(("h2_server", seed.to_bytes()))
      }
    }
  }
  // Programs for the pairs (the step numbers of h2_pair.mbt and
  // h3_pair.mbt): a GET answered; a POST whose body goes both ways; a
  // request reset; with each mode.
  let programs = [
    b"\x00\x01\x00\x05\xff\x02\x01\x00\x00\x06\xff", b"\x00\x00\x01\x01\x00\x10\x41\x00\x05\xff\x02\x00\x00\x00\x03\x00\x20\x42\x00\x06\xff\x07\x05\xff\x06\xff",
    b"\x00\x01\x00\x05\xff\x04\x00\x00\x08\x05\xff\x06\xff",
  ]
  for program in programs {
    for mode in [b'\x00', b'\x01'] {
      let seed = Buffer()
      seed.write_byte(mode)
      seed.write_bytes(program)
      out.push(("h2_pair", seed.to_bytes()))
      out.push(("h3_pair", seed.to_bytes()))
    }
  }
  out
}

///|
fn hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for b in bytes {
    out.write_char(digits[b.to_int() >> 4].unsafe_to_char())
    out.write_char(digits[b.to_int() & 15].unsafe_to_char())
  }
  out.to_string()
}

///|
fn main {
  let args = @env.args()
  // `run TARGET HEX`: one input, to reproduce what a fuzz run kept.
  if args.length() > 3 && args[1] == "run" {
    let text = args[3].to_array()
    let bytes = Bytes::makei(text.length() / 2, i => {
      let digit = (c : Char) => {
        if c <= '9' {
          c.to_int() - '0'.to_int()
        } else {
          c.to_int() - 'a'.to_int() + 10
        }
      }
      (digit(text[2 * i]) * 16 + digit(text[2 * i + 1])).to_byte()
    })
    let result = match args[2] {
      "h2_server" => fuzz_h2_server(bytes)
      "h2_pair" => fuzz_h2_pair(bytes)
      _ => fuzz_h3_pair(bytes)
    }
    println("\{args[2]}: \{result}")
    return
  }
  if args.length() > 1 && args[1] == "seeds" {
    for seed in seeds() {
      println("\{seed.0} \{hex(seed.1)}")
    }
    return
  }
  let mut runs = 0
  for seed in seeds() {
    let (target, bytes) = seed
    ignore(
      match target {
        "h2_server" => fuzz_h2_server(bytes)
        "h2_pair" => fuzz_h2_pair(bytes)
        _ => fuzz_h3_pair(bytes)
      },
    )
    runs += 1
  }
  println("fuzz_ng: \{runs} seed runs")
}
