///|
/// Read at the requested file position with the caller's byte bound.
async fn positioned_read(
  file : @fs.File,
  buffer : FixedArray[Byte],
  position : Int64,
  len : Int32,
) -> Int32 {
  file.at(position).read_into(buffer, max_len=len)
}
