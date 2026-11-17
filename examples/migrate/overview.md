# Migration examples

The before files use MoonBit 0.10.21's `moonbitlang/core/async/http`;
the after files use `gaato/mttp`. See [MIGRATING.md](../../MIGRATING.md)
for the imports and the differences each pair illustrates.

```sh
moon run examples/migrate
```

This runs the client pairs against both servers in the same process over
loopback sockets, checks their results and crosses the request body limit.
It makes no external requests. TLS examples are compiled but not run: they
need a private CA file and a TLS server. The timeout examples exercise only
the successful path; this is not a timing test or a pool reuse measurement.
