// Copyright 2026 International Digital Economy Academy
// Copyright 2026 Gakuto Furuya
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// The wasm engine: moonrun's tls/connection host calls, which core/async's
// TLS uses on wasm. The import declarations follow moonbitlang/core's
// async/tls/tls.wasm.mbt and server_for_wbtest.mbt; changed from them:
// server calls only, paths passed as String with their length (what the host
// reads for an OsString on wasm), and error text read through c_buffer calls
// of our own. These host calls are moonrun's, not a public API: the nightly
// canary is where a change in them shows.

///|
priv struct Engine(UInt64)

///|
/// A buffer the host allocated, holding a NUL-terminated message.
priv struct HostBuffer(UInt64)

///|
#unsafe_skip_stub_check
fn engine_new() -> Engine = "moonbitlang/async" "tls/connection/new"

///|
#unsafe_skip_stub_check
#borrow(key, cert)
fn Engine::set_server_files(
  self : Engine,
  key : String,
  key_len : Int32,
  key_type : Int32,
  cert : String,
  cert_len : Int32,
  cert_type : Int32,
) -> Int32 = "moonbitlang/async" "tls/connection/set_server_files"

///|
#unsafe_skip_stub_check
fn Engine::take_error(self : Engine) -> HostBuffer = "moonbitlang/async" "tls/connection/take_error"

///|
#unsafe_skip_stub_check
#borrow(input, output)
fn Engine::accept_ffi(
  self : Engine,
  input : FixedArray[Byte],
  input_offset : Int32,
  input_len : Int32,
  output : FixedArray[Byte],
  output_offset : Int32,
  output_len : Int32,
) -> Int32 = "moonbitlang/async" "tls/connection/accept"

///|
#unsafe_skip_stub_check
#borrow(input, output, plain)
fn Engine::read_plain_ffi(
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
) -> Int32 = "moonbitlang/async" "tls/connection/read_plain"

///|
#unsafe_skip_stub_check
#borrow(input, output, plain)
fn Engine::write_plain_ffi(
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
) -> Int32 = "moonbitlang/async" "tls/connection/write_plain"

///|
#unsafe_skip_stub_check
fn Engine::bytes_read(self : Engine) -> Int32 = "moonbitlang/async" "tls/connection/bytes_read"

///|
#unsafe_skip_stub_check
fn Engine::bytes_to_write(self : Engine) -> Int32 = "moonbitlang/async" "tls/connection/bytes_to_write"

///|
#unsafe_skip_stub_check
fn Engine::wants_write(self : Engine) -> Bool = "moonbitlang/async" "tls/connection/wants_write"

///|
#unsafe_skip_stub_check
fn Engine::shutdown(self : Engine) -> Int32 = "moonbitlang/async" "tls/connection/shutdown"

///|
#unsafe_skip_stub_check
fn Engine::free(self : Engine) -> Unit = "moonbitlang/async" "tls/connection/free"

///|
#unsafe_skip_stub_check
fn HostBuffer::is_null(self : HostBuffer) -> Bool = "moonbitlang/async" "c_buffer/is_null"

///|
#unsafe_skip_stub_check
fn HostBuffer::strlen(self : HostBuffer) -> Int32 = "moonbitlang/async" "c_buffer/strlen"

///|
#unsafe_skip_stub_check
#borrow(dst)
fn HostBuffer::blit_to(
  self : HostBuffer,
  src_offset : Int32,
  dst : FixedArray[Byte],
  dst_offset : Int32,
  len : Int32,
) -> Unit = "moonbitlang/async" "c_buffer/blit_from_c"

///|
#unsafe_skip_stub_check
fn HostBuffer::free(self : HostBuffer) -> Unit = "moonbitlang/async" "c_buffer/free"

///|
/// The X509 file type moonrun reads for PEM.
const PEM : Int32 = 1

///|
fn Engine::new(key_file~ : String, cert_file~ : String) -> Engine raise {
  let engine = engine_new()
  let status = engine.set_server_files(
    key_file,
    key_file.length(),
    PEM,
    cert_file,
    cert_file.length(),
    PEM,
  )
  if status != 0 {
    let message = engine.error()
    engine.free()
    raise Failure(message)
  }
  engine
}

///|
/// The session's last error.
fn Engine::error(self : Engine) -> String {
  let buf = self.take_error()
  guard !buf.is_null() else { "unknown TLS error" }
  let len = buf.strlen()
  let data = FixedArray::make(len, b'\x00')
  buf.blit_to(0, data, 0, len)
  buf.free()
  @utf8.decode_lossy(data.unsafe_reinterpret_as_bytes())
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
/// The host keeps ciphertext it could not hand over; a handshake step on an
/// established session hands it over and does nothing else (core's
/// `Tls::shutdown` drains the same way).
fn Engine::drain(self : Engine, output : Window) -> Unit {
  let none = FixedArray::make(0, b'\x00')
  ignore(self.accept_ffi(none, 0, 0, output.buf, output.end(), output.room()))
}
