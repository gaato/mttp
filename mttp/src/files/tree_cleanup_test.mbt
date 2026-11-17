///|
/// Remove the fixture tree, including directories created by a test.
async fn remove_tree(path : String) -> Unit nocancel {
  @fs.remove(path, recursive=true)
}
