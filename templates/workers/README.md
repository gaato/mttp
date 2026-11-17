# Cloudflare Workers

Use MoonBit 0.10.21 and Node.js. From this copied directory:

```sh
moon update
moon check --target js --deny-warn
moon test --target js
npx wrangler@4.162.0 dev
```

Wrangler runs `moon build --target js --release` before starting the Worker.
Open <http://localhost:8787/hello/Moon> for a JSON greeting. The entry imports
the compiled module inside the first request because Workers disallows the
randomness used by MoonBit's hash seed during global initialization. This
follows the build and fetch-adapter pattern in mttp's `examples/fetch/workers`.

Add endpoints and implementations in `src/app.mbt`. Tests call the same
definitions through a Router Backend without sockets or a Workers account.
The fetch adapter keeps its default bounded body handling and passes host
bindings and background work through `fetch_with_env`.

To deploy, choose a unique `name` in `wrangler.toml`, authenticate Wrangler
with your Cloudflare account, then run:

```sh
npx wrangler@4.162.0 deploy
```
