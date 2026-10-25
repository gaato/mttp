///|
test "split generators preserve bytes and cover endpoints" {
  let bytes = @model.encode_utf8("日本🙂")
  let offsets = []
  @gen.each_split(bytes, (a, b) => {
    let out = Buffer()
    out.write_bytes(a)
    out.write_bytes(b)
    assert_eq(out.to_bytes(), bytes)
    offsets.push(a.length())
  })
  assert_eq(offsets, Array::makei(bytes.length() + 1, i => i))
  assert_eq(@gen.byte_chunks(bytes).length(), bytes.length())
  for chunks in @gen.chunks(bytes).samples(count=100, seed=42) {
    let out = Buffer()
    for chunk in chunks {
      assert_true(!chunk.is_empty())
      out.write_bytes(chunk)
    }
    assert_eq(out.to_bytes(), bytes)
  }
  assert_eq(@gen.chunks(b"").sample(seed=42), [])
}

///|
test "generated controls are refused and text generation is reproducible" {
  let first = @gen.text().samples(count=100, size=20, seed=42)
  assert_eq(first, @gen.text().samples(count=100, size=20, seed=42))
  for url in @gen.invalid_url().samples(count=100, seed=42) {
    let refused = try {
      @model.validate_url(url)
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  }
  for headers in @gen.headers().samples(count=100, size=10, seed=42) {
    assert_eq(headers.length(), 10)
    assert_eq(headers.get_all("X-TEST"), headers.get_all("x-test"))
  }
}
