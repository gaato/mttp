# API server

Use MoonBit 0.10.21 and a C compiler. From this copied directory:

```sh
moon update
moon check --target native --deny-warn
moon test --target native
API_TOKEN=local-example-token moon run src/main --target native
```

The server listens on `127.0.0.1:8080`. Set `LISTEN_ADDR` to change it.
Set `API_TOKEN` to your own non-empty secret. The endpoints are:

- `GET /hello/{name}` returns a JSON string.
- `POST /echo` accepts a JSON string of 1–80 characters and returns it.
  Invalid JSON or validation errors produce a 400 problem response.
- `GET /account` requires `Authorization: Bearer <API_TOKEN>`.

OpenAPI is at <http://127.0.0.1:8080/openapi.json> and the Docs UI is at
<http://127.0.0.1:8080/docs>. The page loads its pinned renderer from jsDelivr;
the JSON specification and tests need no network.

Add definitions in `src/api.mbt`, register their implementations in
`application`, and include their `doc()` in `specification`. Those definitions
also supply the typed client. Tests use the Router as a Backend without sockets
and keep an OpenAPI golden. Review specification changes before accepting
them with `moon test --target native --update`.

Requests share a 60-per-minute service budget. The Router accepts at most
4 KiB of body data; the server additionally keeps its default 256-connection
cap, 1 MiB transport body limit and five-second head/body budgets. Secure
headers apply to every response, including refusals. Terminate TLS at your
deployment proxy. SIGINT and SIGTERM cancel the listener, stop acceptance,
and allow active responses up to the default ten-second drain period.

Build a container with the pinned toolchain image:

```sh
docker build -t my-api .
docker run --rm -p 8080:8080 -e API_TOKEN=local-example-token my-api
```

The image listens on all interfaces and runs as a non-root user.
