///|
/// Runs each target once on a valid input, so the gates' native build of
/// this package links and exercises both entry points.
fn main {
  let h1 = fuzz_h1(b"\x00\x00\x10GET / HTTP/1.1\r\nHost: h\r\n\r\n")
  let ws = fuzz_ws(b"\x0c\x00\x02\x81\x05Hello")
  println("h1 \{h1} ws \{ws}")
}
