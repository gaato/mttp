# Tour example

One typed endpoint, `GET /hello/{name}`, used three ways: served by a
Router, called with the typed client and documented as OpenAPI 3.1. From the
repository root:

```sh
moon run examples/tour                       # call it in-process, print the document
moon run examples/tour -- 127.0.0.1:8080     # serve it on a port
```

The repository's README shows this file and part of what it prints;
`scripts/readme_check.mbtx` keeps the two equal.
