# gaato/mttp_digest

HTTP Digest authentication (RFC 7616) for an mttp client, scoped to one
origin. Use it for devices and services that answer with
`WWW-Authenticate: Digest`. The wrapper reads the server's 401 challenge,
computes the `Authorization` header and resends the request, while the client
keeps its usual redirects and retry policy.

It is a module of its own so that only programs that use Digest depend on
`moonbitlang/x` for its hashes.

## Install

```sh
moon add gaato/mttp_digest
moon add gaato/mttp
```

Import both in the `moon.pkg` of the package that builds the client.

## Wrap the network backend

`DigestScheme` wraps the backend that sends the requests, and the client goes
on top of it. Because the client follows redirects outside the wrapper, every
redirect hop passes through it and is checked against the credential origin,
and the retry policy sees the whole exchange, challenge included.

```mbt nocheck
///|
/// A client that answers the Digest challenges of api.example.com.
fn api_client(user : String, password : String) -> @mttp.Client raise {
  @mttp.client(
    backend=@mttp_digest.DigestScheme::new(
      @mttp.backend(),
      user,
      password,
      origin="https://api.example.com",
      random=secure_random,
    ),
  )
}
```

A library builds its client the same way with `Client::new` from
`gaato/mttp_core/client`, wrapping whatever backend its caller supplies.

## Random source

`random` returns values in [0, 1), from which the wrapper makes its client
nonces. Digest relies on those being unpredictable, so `random` must come from
a secure source. `@env.rand` in `moonbitlang/core/env` reads the platform's:
the operating system's generator on native, WASI's `random_get` on wasm, and
`crypto.getRandomValues` on js. It returns `None` where there is none, such as
on wasm-gc. Refuse to go on then, rather than fall back to a predictable
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

## Which requests are authenticated

- **One origin.** `origin` is an absolute HTTP or HTTPS URL without userinfo.
  Its path does not matter. Requests to another origin pass through without
  credentials. A request that sets its own `Authorization` header is sent as
  it is.
- **Resendable bodies only.** Answering a challenge means sending the request
  again. Empty and byte bodies are resent. A stream body never is, so a request
  with one gets the 401 back.
- **One answer.** The wrapper answers one challenge, and one more if the server
  says the nonce was stale. Any other 401 reaches the caller unchanged.
- **No silent replays.** Once a challenge has been answered, the server has
  seen the request, so a later transport failure is reported with phase
  `Unknown` (`Connect` and `Proxy` become `Network`). A retry rule that repeats
  only unsent requests then does not resend a POST. The original error stays in
  the detail.

## Supported challenges

MD5, SHA-256 and their `-sess` forms, `qop=auth` and `auth-int`, `userhash`,
UTF-8 usernames, and legacy challenges without `qop` (except for the `-sess`
forms). A challenge it does not support, such as SHA-512-256, returns the 401
unchanged.

## License

Apache-2.0. See [LICENSE](https://github.com/gaato/mttp/blob/main/mttp_digest/LICENSE).
