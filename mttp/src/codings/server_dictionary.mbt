///|
/// A dictionary a server compresses responses with (RFC 9842): its bytes,
/// their SHA-256, and the id it was served with. The Brotli and Zstandard
/// forms are built once and shared by every response that uses it.
pub struct ServerDictionary {
  /// The dictionary's bytes.
  content : Bytes
  /// SHA-256 of `content`, as `Available-Dictionary` names it.
  hash : Bytes
  /// The `id` it was served with in `Use-As-Dictionary`, or "" for none.
  id : String
  priv brotli : @brotli.Dictionary
  priv zstd : @zstd.Dictionary
}

///|
/// A dictionary of `content`. `sha256` hashes it (32 bytes out); mttp
/// carries no SHA-256, so the caller passes one, such as
/// `moonbitlang/x/crypto`'s.
pub fn ServerDictionary::new(
  content : Bytes,
  sha256~ : (BytesView) -> Bytes,
  id~ : String = "",
) -> ServerDictionary {
  {
    content,
    hash: sha256(content),
    id,
    brotli: @brotli.Dictionary(content),
    zstd: @zstd.Dictionary::raw(content),
  }
}
