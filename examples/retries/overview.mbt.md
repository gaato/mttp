# Retries example

Starts a server on a free local port that answers 503 twice and then 200,
calls it with the retry policy and budget `@mttp_async.client()` uses by
default, and prints each attempt with the wait the policy chose. From the
repository root:

```sh
moon run examples/retries
```

The jitter is fixed at the middle of its range, so the output is the same on
every run. The repository's README shows that output;
`scripts/readme_check.mbtx` keeps the two equal.
