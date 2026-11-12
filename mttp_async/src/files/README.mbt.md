# gaato/mttp_async/files

A directory's files as a handler, for native and wasm (under moonrun).

`static_files(root, prefix?, cache_control?, index?)` is a Handler that
serves the files below the directory `root` to GET and HEAD requests whose
path lies below `prefix` (`/` by default). Serve it with
`gaato/mttp_async/server` like any other handler:

```mbt nocheck
@server.serve(@files.static_files("public"), addr="127.0.0.1:8080")
```

## What it answers

- A path below `prefix` names a file below `root`: with `prefix="/assets/"`,
  `/assets/css/site.css` is `root/css/site.css`. The prefix is compared
  segment by segment with the decoded path, so `/assets`, `/assets/` and
  `assets` mean the same, and `/assetsx/` does not match.
- A path ending in `/` names a directory and serves its `index` file
  (`index.html` by default; `index=""` serves none). Directories are never
  listed. A directory named without the trailing slash, such as `/docs` or
  the prefix itself, is a 404: no redirect is sent.
- A 200 carries `Content-Type` from the file's extension, ignoring case:
  html and htm, css, js and mjs, txt (all `charset=utf-8`), json and map
  (`application/json`), svg, png, jpg and jpeg, gif, webp, ico, wasm and
  woff2; anything else is `application/octet-stream`. It also carries a weak
  `ETag` made from the size and the modification time, `Last-Modified`, and
  `Cache-Control` from the option (`no-cache` by default, so a browser
  revalidates each time; `""` leaves the field out).
- An `If-None-Match` that matches the `ETag` under the weak comparison, or is
  `*`, gets a 304 with the `ETag` and `Cache-Control` and no body.
  `If-Modified-Since` is not evaluated: every answer carries an `ETag`, so a
  cache that revalidates sends `If-None-Match`, and when both fields are
  sent `If-None-Match` takes precedence (RFC 9110, section 13.1.3).
- HEAD gets the same fields as GET without a body, and without
  `Content-Length`: the connection engine writes it only from a body, and
  RFC 9110, section 9.3.2, lets a HEAD answer omit fields that are
  determined while generating the content.
- Other methods below `prefix` get a 405 with `Allow: GET, HEAD`; a path
  outside `prefix` is a 404 whatever the method. The request body is closed
  unread.
- Ranges are not supported: `Range` is ignored and a GET is always a 200
  with the whole file. The handler is meant for an app's assets
  (stylesheets, scripts, images), which are fetched whole; media that must
  resume or seek belongs in an endpoint of its own.
- Hidden files are never served: a segment starting with `.`, such as
  `/.env`, `/.git/config` or `/%2eenv`, is a 404, and there is no option to
  serve them. Deployed directories often hold a `.git` or `.env` that must
  not leak (Express's serve-static ignores dotfiles by default for the same
  reason). This includes `/.well-known/`; answer those paths with an
  endpoint.

Every refusal and every lookup failure is the same plain-text 404, with
nothing about the file system in it.

## What stays inside `root`

The guarantee: a request is answered only from a regular file whose real
path, after every symlink is resolved, lies below the real path of `root`.
It holds for the file system as it is when the request is checked. Three
checks enforce it, each enough for the path tricks it names:

1. **The path.** Each segment is percent-decoded on its own. A segment that
   starts with `.` once decoded (which covers `.` and `..`), contains `/`,
   `\` or NUL, or is empty (other than the final one of a directory path),
   or does not decode as UTF-8, is a 404. Dot segments are refused as sent,
   not normalized away, so
   `/a/../b`, `/%2e%2e/secret` and `/..%2fsecret` are all 404, and so are
   `//etc/passwd` and `/C:%5Cwindows`. The `index` option is checked the
   same way.
2. **The real path.** `root` and the requested file are resolved with
   core/async's `realpath`, and the file's must equal or start with the
   root's followed by a separator. A symlink inside `root` whose target is
   also inside is served; one pointing outside is a 404. Because `root` is
   resolved on every request, `root` may itself be a symlink that a deploy
   swaps.
3. **The kind.** Only a regular file is opened (a FIFO would block on open),
   and the opened file is checked again.

core/async's file system API has no `openat` or `O_NOFOLLOW`, so the checks
and the open are separate calls: someone who can write below `root` while
it is served could swap a checked path for a symlink between the check and
the open. Serve only directories that the server's untrusted users cannot
write to.

## Memory and bounds

A GET's body is the open file, read in slices of at most 64 KiB as the
connection pulls them, so memory per response does not grow with the file.
The size declared in the response is the size when the file was opened: a
file that grows is cut at that size, and one that shrinks ends the body with
a `Protocol` error, which closes the connection. Each response in flight
holds one open file and one buffer, and the listener's `max_connections`
bounds how many are in flight.

## With a Router

A Router answers 404 for a path none of its endpoints matches. Give such
requests to the files:

```mbt check
///|
/// The app: its API through `api`, and the files below `public` for every
/// path the API does not know.
fn app(api : @router.Router) -> @mttp.Handler {
  let assets = @files.static_files("public")
  async fn(request) noraise {
    let response = api.dispatch(request)
    guard response.status == 404 else { response }
    response.close()
    assets(request)
  }
}

///|
async test "the router answers first and the files after it" {
  let hello = @endpoint.endpoint.get("/hello").output(@endpoint.text_out())
  let api = @router.Router::new([hello.serve_public(_ => Ok("hello"))])
  let handler = app(api)
  assert_eq(handler(@mttp.Request::get("/hello")).body, @mttp.Bytes(b"hello"))
  assert_eq(handler(@mttp.Request::get("/missing.css")).status, 404)
  api.close()
}
```

With `prefix="/"` the files answer 405 to a POST to a path the API does not
know; give them a prefix such as `/assets/` to keep the rest of the space
404. The same fallback can be a middleware in the Router's
`ServerOptions.middleware`, which then also runs the other middleware (such
as `access_log`) for the files.
