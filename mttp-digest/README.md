# mttp-digest

Digest authentication is isolated here so clients that do not use it do not
download `moonbitlang/x`. `DigestScheme` wraps a single-exchange Backend and
implements the same Backend interface. Configure an explicit credential origin
and an injected random source. Put it inside `FollowRedirects` so each hop is
checked against that origin before credentials are generated.

The implementation retains requesto's MD5/SHA-256, session, auth/auth-int,
userhash and UTF-8 username handling. SHA-512-256 is unsupported. It answers
one 401, with at most one further answer to a stale nonce, and only replays
in-memory request bodies. Explicit Authorization headers are left alone.

Responses replaced by authentication retries are closed first. Challenges are
limited to 16 KiB in total; oversized or unsupported challenges are returned as
ordinary 401 responses. As with other wrappers, use a Client Timer to enforce
a deadline across the complete exchange, rather than only each backend send.
