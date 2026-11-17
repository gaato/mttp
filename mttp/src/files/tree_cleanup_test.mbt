///|
/// Kept separate so newer toolchains can use fs.remove without a deprecated
/// rmdir call; 0.10.20 does not accept remove's recursive argument.
async fn remove_tree(path : String) -> Unit nocancel {
  @fs.rmdir(path, recursive=true)
}
