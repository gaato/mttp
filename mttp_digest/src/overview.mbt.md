# gaato/mttp_digest

HTTP Digest authentication for `gaato/mttp_core` backends, scoped to one origin.

It is a module of its own so that only the programs that use Digest depend
on `moonbitlang/x` for its hashes.

## Install

```sh
moon add gaato/mttp_digest
```

## Usage

`DigestScheme` wraps the backend that sends the requests, and the `Client`
goes on top of it. The Client follows redirects outside the wrapper, so every
redirect hop passes through it and is checked against the credential origin,
and its retry policy sees the outcome of the whole exchange, challenge
included. In an app on
[`gaato/mttp_async`](https://mooncakes.io/docs/gaato/mttp_async), wrap the
network backend and hand it to `client()`, which keeps its defaults:

```mbt nocheck
///|
/// A client that answers the Digest challenges of api.example.com.
fn api_client(user : String, password : String) -> @mttp_async.Client raise {
  @mttp_async.client(
    backend=@mttp_digest.DigestScheme::new(
      @mttp_async.backend(),
      user,
      password,
      origin="https://api.example.com",
      random=secure_random,
    ),
  )
}
```

The package importing this lists `gaato/mttp_async` and `gaato/mttp_digest`,
and so does the app's `moon.mod`. A library builds its Client the same way
with `Client::new` from `gaato/mttp_core/client`.

## Random source

`random` returns values in [0, 1) from which the wrapper makes its client
nonces. Digest relies on those being unpredictable, so `random` must come from
a secure source. `@env.rand` in `moonbitlang/core/env` reads the platform's:
the operating system's generator on native, WASI's `random_get` on wasm, and
`crypto.getRandomValues` on js. It returns `None` where there is none, such as
on wasm-gc; refuse to go on then rather than fall back to a predictable
sequence:

```mbt check
///|
/// A sample in [0, 1) with 32 bits from the platform's secure random source.
fn secure_random() -> Double {
  guard @env.rand(4) is Some(bytes) else {
    abort("no secure random source on this platform")
  }
  let mut value = 0UL
  for byte in bytes {
    value = (value << 8) | byte.to_uint64()
  }
  value.to_double() / 4294967296.0
}

///|
test "secure_random stays in [0, 1)" {
  if @env.rand(0) is Some(_) {
    let sample = secure_random()
    assert_true(sample >= 0.0 && sample < 1.0)
  }
}
```

In tests, a fixed source such as `random=() => 0.5` makes the nonces
repeatable.

## Scope

The origin must be an absolute HTTP(S) URL without userinfo; its path does not
matter. Requests to another origin pass through without credentials, and a
request that sets its own `Authorization` header is sent as it is.

The wrapper answers one challenge, and one more if the server says the nonce
was stale; any other 401 reaches the caller unchanged. It answers only when it
can resend the body: empty and byte bodies are resent, a stream body never is,
so a request with one gets the 401 back. Once a challenge has been answered,
a transport failure has phase `Unknown` (`Connect` and `Proxy` become
`Network`), because the server already saw the request: a retry rule that
repeats only unsent requests does not resend a POST, and the original error
stays in the detail.

It supports MD5, SHA-256 and their `-sess` forms, `qop=auth` and `auth-int`,
`userhash` and UTF-8 usernames, and legacy challenges without `qop` (except
for the `-sess` forms). A challenge it does not support, such as SHA-512-256,
returns the 401 unchanged.

## License

Apache-2.0. See [LICENSE](https://github.com/gaato/mttp/blob/main/mttp_digest/LICENSE).
