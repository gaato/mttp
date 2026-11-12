// The bytes the interop programs exchange, and how they are compared. The
// Go, Python and JavaScript clients under interop/clients implement the same
// two functions (`binary` and `Digest`) so that every party can produce and
// check the same bodies without shipping them.

///|
/// The byte at offset `i` of every generated binary body: `(7i + i/256) mod
/// 256`. It does not repeat with a short period, so a dropped, repeated or
/// reordered piece of a body changes its digest.
pub fn byte_at(i : Int32) -> Byte {
  ((i * 7 + (i >> 8)) & 0xff).to_byte()
}

///|
/// `n` bytes of the binary pattern.
pub fn binary(n : Int32) -> Bytes {
  Bytes::makei(n, byte_at)
}

///|
/// `n` bytes of compressible text: numbered lines of the same sentence, so
/// every server's encoder has something to shrink.
pub fn text(n : Int32) -> Bytes {
  let out = Buffer(size_hint=n + 64)
  let mut line = 0
  while out.length() < n {
    line += 1
    let number = line.to_string().pad_start(6, '0')
    out.write_string_utf8(
      "\{number} the quick brown fox jumps over the lazy dog\n",
    )
  }
  out.to_bytes()[:n].to_owned()
}

///|
/// A running FNV-1a (32 bit) digest and byte count of a body.
pub struct Digest {
  priv mut length : Int64
  priv mut hash : UInt32
}

///|
/// An empty digest.
pub fn Digest::new() -> Digest {
  { length: 0L, hash: 0x811c9dc5U, }
}

///|
/// Adds `bytes` to the digest.
pub fn Digest::update(self : Digest, bytes : BytesView) -> Unit {
  let mut hash = self.hash
  for b in bytes {
    hash = (hash ^ b.to_uint()) * 0x01000193U
  }
  self.hash = hash
  self.length += bytes.length().to_int64()
}

///|
/// `<length>:<hash in hex>`, the form every interop party prints.
pub fn Digest::summary(self : Digest) -> String {
  let hex = self.hash.to_string(radix=16).pad_start(8, '0')
  "\{self.length}:\{hex}"
}

///|
/// The digest summary of `bytes`.
pub fn digest(bytes : BytesView) -> String {
  let d = Digest::new()
  d.update(bytes)
  d.summary()
}

///|
/// Sizes of the static files, which the client and the docroot share.
pub let large_bytes : Int32 = 16 << 20

///|
/// The static files every server serves from its document root, by name.
/// `slow.bin` is the file the servers send at a limited rate; `upload.bin`
/// is what curl uploads.
pub fn files() -> Array[(String, Bytes)] {
  [
    ("small.txt", b"hello interop\n"),
    ("text.txt", text(256 << 10)),
    ("large.bin", binary(large_bytes)),
    ("slow.bin", binary(16 << 10)),
    ("upload.bin", binary(2 << 20)),
  ]
}

///|
/// `digests.txt` beside the files: `<name> <digest summary>` per file, and
/// `binary-4000` for the body curl's HTTP/1.0 case downloads, so a shell
/// script can check what the server received without computing a digest.
pub fn digests() -> String {
  let lines = files().map(file => "\{file.0} \{digest(file.1)}")
  lines.push("binary-4000 \{digest(binary(4000))}")
  lines.join("\n") + "\n"
}
