# GET example

Prints the status, response headers and decoded body length of one request.
The exchange has a 30 second deadline and 64 MiB limits on both wire and
decoded bytes. Redirects are returned to the caller.

## Install

Run this workspace example directly; it is not published. From the root:

```sh
moon run --target native examples/get -- https://example.com/
moon build --target wasm examples/get
```

## License

Apache-2.0
