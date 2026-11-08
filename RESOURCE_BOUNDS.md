# Resource bounds

What a long-running client, server or parser built on `gaato/http`,
`gaato/http-async`, `gaato/mttp` or `gaato/mttp-digest` can accumulate, and
what keeps each structure from growing without limit. The rule: **every
structure that grows with input from the network, a peer, or the number of
requests, buckets, connections or pending calls is listed here with its
bound**. A new one, such as a map keyed by names that arrive from outside or a
buffer filled from a stream, needs a row before it ships.

A bound is either a limit the code enforces, or the rate of the input times
how long an entry lives, where both are themselves bounded. Rows of the second
kind say what that product is. Bounded by default: a limit has a default, and
input past it is refused rather than degraded.

A body that may be compressed has two bounds, and each gets its own row: the
bytes read from the wire (enforced by the connection engine) and the bytes
after decoding (enforced by the decoder and the mttp client). One row for both
would hide a decompression bomb that stays under the wire limit.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests, as in `` `http/src/h1/head_test.mbt`: "first", "second" ``. A test
counts only if it drives the structure to its limit and one past it, or pins a
default the row states; one that merely uses the feature does not.
`scripts/bounds_check.mbtx`, run by `scripts/gates.sh`, enforces the naming: it
fails when a row names no test or a named test is not declared in the named
file. Whether a named test really reaches the bound is checked in review. The
other tables describe where no limit is enforced, so they stay prose.

Test helpers (`gaato/http/sim`, `gaato/http/driver`, `gaato/mttp/testing`)
record what a test feeds them and are not listed, except the limits that keep
a test from hanging.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|

## Bounded by rate and lifetime

| Structure | Grows with | Bound |
|---|---|---|

## Left to the caller

Growth that follows what the caller asks for, not what the network sends.

| Structure | Grows with | Why it is not bounded here |
|---|---|---|

## Known gaps

Growth the library does not bound yet, with what limits it in practice and how
it could be fixed.

| Structure | Grows with | What limits it | Suggested fix |
|---|---|---|---|
