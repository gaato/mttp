# Endpoint definition

The fetch host and the in-process client share this definition:

```mbt check
///|
test "definition supplies documentation" {
  assert_eq(@worker.hello.doc().template, "/hello/{name}")
}
```
