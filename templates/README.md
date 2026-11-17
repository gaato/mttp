# Templates

Use [api-server](api-server/README.md) for a native HTTP server with typed
endpoints, authentication, OpenAPI and a documentation page. Use
[workers](workers/README.md) for a JavaScript service on Cloudflare Workers.

From a checkout of this repository, copy one directory outside the checkout:

```sh
cp -R templates/api-server ../my-api
# Or: cp -R templates/workers ../my-worker
```

Each copy is an independent MoonBit module. Its dependency pins match the
versions in this checkout and resolve from the registry after those versions
are released. Run the commands in its README from the copied directory.

For an SDK starter, use [moonbit-sdks](https://github.com/gaato/moonbit-sdks),
which owns SDK generation, checks and releases.

The repository checks these directories with
`moon run scripts/templates_gate.mbtx`. They are deliberately outside
`moon.work` and `scripts/modules.tsv`: they are copied applications, not
published modules or workspace examples. The gate stages fresh copies under
`_build/` with local dependencies, checks pins, checks and tests each target,
and builds the entry points. `--self-test` verifies that changed pins fail.
The docs audit discovers their Markdown automatically. The template gate
checks their tests directly, so they need no test manifest or test-layout
exceptions.
