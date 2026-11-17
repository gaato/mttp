///|
async fn main {
  let args = @env.args()[1:].to_owned()
  let check = args.contains("--check")
  let paths = args.filter(arg => arg != "--check")
  guard paths.length() >= 2 else {
    fail("usage: schemagen [--check] OUTPUT INPUT.mbt [INPUT.mbt ...]")
  }
  let sources = []
  for path in paths[1:] {
    sources.push((path, @fs.read_text(path)))
  }
  let output = formatted(generate(sources))
  if check {
    guard @fs.read_text(paths[0]) == output else {
      fail("stale generated source: \{paths[0]}")
    }
  } else {
    @fs.write_text(paths[0], output)
  }
}

///|
// Use the active compiler's formatter: parser 0.4.8's formatter can emit
// newer syntax than moonc 0.10.20 understands. Stdin avoids temporary files
// and keeps --check read-only.
async fn formatted(source : String) -> String {
  let result = @shell.Cmd("moonfmt", ["-"], stdin=Text(source)).output(
    timeout_ms=30000,
    max_output_bytes=16 * 1024 * 1024,
  )
  result.check()
  result.stdout()
}
