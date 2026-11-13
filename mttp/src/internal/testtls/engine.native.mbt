// The native engine: OpenSSL through testtls.c, with mttp's own symbols.

///|
#external
priv type Engine

///|
#borrow(key, cert)
extern "C" fn engine_new(key : Bytes, cert : Bytes) -> Engine = "mttp_testtls_new"

///|
extern "C" fn Engine::is_null(self : Engine) -> Bool = "mttp_testtls_is_null"

///|
#borrow(buf)
extern "C" fn engine_error(
  engine : Engine,
  buf : FixedArray[Byte],
  len : Int32,
) -> Int32 = "mttp_testtls_error"

///|
#borrow(input, output)
extern "C" fn Engine::accept_ffi(
  self : Engine,
  input : FixedArray[Byte],
  input_offset : Int32,
  input_len : Int32,
  output : FixedArray[Byte],
  output_offset : Int32,
  output_len : Int32,
) -> Int32 = "mttp_testtls_accept"

///|
#borrow(input, output, plain)
extern "C" fn Engine::read_plain_ffi(
  self : Engine,
  input : FixedArray[Byte],
  input_offset : Int32,
  input_len : Int32,
  output : FixedArray[Byte],
  output_offset : Int32,
  output_len : Int32,
  plain : FixedArray[Byte],
  plain_offset : Int32,
  plain_len : Int32,
) -> Int32 = "mttp_testtls_read_plain"

///|
#borrow(input, output, plain)
extern "C" fn Engine::write_plain_ffi(
  self : Engine,
  input : FixedArray[Byte],
  input_offset : Int32,
  input_len : Int32,
  output : FixedArray[Byte],
  output_offset : Int32,
  output_len : Int32,
  plain : Bytes,
  plain_offset : Int32,
  plain_len : Int32,
) -> Int32 = "mttp_testtls_write_plain"

///|
#borrow(output)
extern "C" fn Engine::drain_ffi(
  self : Engine,
  output : FixedArray[Byte],
  output_offset : Int32,
  output_len : Int32,
) -> Int32 = "mttp_testtls_drain"

///|
extern "C" fn Engine::bytes_read(self : Engine) -> Int32 = "mttp_testtls_bytes_read"

///|
extern "C" fn Engine::bytes_to_write(self : Engine) -> Int32 = "mttp_testtls_bytes_to_write"

///|
extern "C" fn Engine::wants_write(self : Engine) -> Bool = "mttp_testtls_wants_write"

///|
extern "C" fn Engine::shutdown(self : Engine) -> Int32 = "mttp_testtls_shutdown"

///|
extern "C" fn Engine::free(self : Engine) -> Unit = "mttp_testtls_free"

///|
/// A NUL-terminated copy of `path` for C.
fn c_path(path : String) -> Bytes {
  let buffer = Buffer()
  buffer.write_bytes(@utf8.encode(path))
  buffer.write_byte(b'\x00')
  buffer.to_bytes()
}

///|
fn Engine::new(key_file~ : String, cert_file~ : String) -> Engine raise {
  let engine = engine_new(c_path(key_file), c_path(cert_file))
  if engine.is_null() {
    raise Failure(engine.error())
  }
  engine
}

///|
/// The session's last error; for a null engine, why it failed to start.
fn Engine::error(self : Engine) -> String {
  let buf = FixedArray::make(256, b'\x00')
  let len = engine_error(self, buf, buf.length())
  @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:len])
}

///|
fn Engine::accept(self : Engine, input : Window, output : Window) -> State {
  match
    self.accept_ffi(
      input.buf,
      input.start,
      input.len,
      output.buf,
      output.end(),
      output.room(),
    ) {
    0 => Completed
    1 => WantRead
    2 => WantWrite
    4 => Eof
    _ => Error
  }
}

///|
fn Engine::read_plain(
  self : Engine,
  input : Window,
  output : Window,
  plain : FixedArray[Byte],
) -> Int32 {
  self.read_plain_ffi(
    input.buf,
    input.start,
    input.len,
    output.buf,
    output.end(),
    output.room(),
    plain,
    0,
    plain.length(),
  )
}

///|
fn Engine::write_plain(
  self : Engine,
  output : Window,
  plain : Bytes,
  offset : Int32,
) -> Int32 {
  let none = FixedArray::make(0, b'\x00')
  self.write_plain_ffi(
    none,
    0,
    0,
    output.buf,
    output.end(),
    output.room(),
    plain,
    offset,
    plain.length() - offset,
  )
}

///|
fn Engine::drain(self : Engine, output : Window) -> Unit {
  ignore(self.drain_ffi(output.buf, output.end(), output.room()))
}
