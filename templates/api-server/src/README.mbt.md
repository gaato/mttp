# Endpoint definitions

Server routing, clients and documentation share these definitions:

```mbt check
///|
test "definitions supply documentation" {
  assert_eq(@api.hello.doc().template, "/hello/{name}")
}
```
