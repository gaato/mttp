# Serve example

Run the HTTP/1 server on a local address:

```sh
moon run --target native examples/serve -- 127.0.0.1:8080
```

It returns 200 and `hello` on every path, supports keep-alive and uses the
default bounded server limits. Cancellation stops acceptance and drains
responses and background jobs before returning.
