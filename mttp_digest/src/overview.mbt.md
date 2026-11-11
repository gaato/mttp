# gaato/mttp_digest

Origin-scoped HTTP Digest authentication for `gaato/http` backends and the
`gaato/mttp` client. Keeping it in a separate module makes the
`moonbitlang/x` crypto dependency optional for other clients.

## Install

```sh
moon add gaato/http gaato/mttp gaato/mttp_digest
```

## Usage

```mbt check
///|
test {
  let inner = @client.from_fn((_, _) => @mttp.Response::new(200))
  let backend = @mttp_digest.DigestScheme::new(
    inner,
    "user",
    "password",
    origin="https://api.example.test",
    random=() => 0.5, // deterministic test source; inject secure randomness in production
  )
  @driver.run_sync(() => {
    let response = backend.send(
      @mttp.Request::get("https://api.example.test/"),
      @mttp.SendOptions::default(),
    )
    assert_eq(response.status, 200)
    response.close()
  })
  backend.close()
}
```

Inject an unpredictable source of values in `[0, 1)` in production. Each
cnonce uses four draws (128 bits); the nonce count starts at one and is sent
as eight hex digits. Concurrent calls share increasing counts, including
responses to challenges with an already-used nonce. A new nonce or a
`stale=true` challenge resets the count to one. The origin must be an absolute
HTTP(S) URL without userinfo. Paths do not affect its scope. Explicit
`Authorization` headers take precedence; requests to another origin pass
through without credentials.

Place `DigestScheme` inside `FollowRedirects` so every hop is checked against
the credential origin, and put the `Client` outside both wrappers. Retry
policies then see the outcome of the whole exchange. A failure after an
answered 401 has phase `Unknown`, with `Connect`/`Proxy` mapped to `Network`,
so an unsent-only retry rule cannot repeat an already answered POST. The
original error remains in the detail.

The wrapper answers one challenge and, if necessary, one further
`stale=true` challenge. It closes intermediate responses unread and keeps
the final body owned by the caller. It passes `SendOptions` through unchanged
on every send; a `Client` with a Timer bounds the whole exchange. Request
streams close on every exit, including validation refusal and cancellation,
and are never replayed to answer a challenge. Empty and byte bodies can be
resent. Close is idempotent and clears retained nonces.

Supported algorithms are MD5, SHA-256 and their `-sess` forms, with `auth`
preferred over `auth-int` (the latter requires a buffered body), userhash
and UTF-8 `username*`. Legacy non-session challenges without qop are also
accepted, without preemptive nonce reuse. `-sess` without qop and
SHA-512-256 challenges are declined, as in the original implementation:
`moonbitlang/x` does not provide SHA-512/256's distinct initialization values.

All `WWW-Authenticate` values together have a 16 KiB UTF-8 budget; a larger
challenge returns the 401 unchanged. The nonce store retains at most 16
origins, evicts the oldest on overflow and forgets a nonce when its count
would exceed `ffffffff`. A same-nonce challenge at exhaustion returns the
401 unchanged rather than reusing a count. Each wrapper is scoped to one origin.

## License

Apache-2.0. See [LICENSE](https://github.com/gaato/mttp/blob/main/mttp_digest/LICENSE).
