# GET example

One GET request with the Client an app starts with: `@mttp.client()` retries
idempotent requests within a budget, keeps a 30 s attempt and 120 s call
deadline, follows redirects and decompresses the body. It prints the status
and the length of the text. The package imports `gaato/mttp` and nothing
else.

## Run

Run this workspace example directly; it is not published. From the root:

```sh
moon run examples/get
moon run --target js examples/get
moon run --target wasm examples/get
```

## License

Apache-2.0
