///|
/// Keep the version-specific positioned read here so the canary can replace
/// it without changing file-body ownership or range accounting.
async fn positioned_read(
  file : @fs.File,
  buffer : FixedArray[Byte],
  position : Int64,
  len : Int32,
) -> Int32 {
  file.read_at(buffer, position~, len~)
}
