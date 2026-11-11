///|
/// Builds a tree in a fresh temporary directory, runs `body` with the path
/// of its `public` directory (the served root) and removes the tree:
///
/// ```text
/// secret.txt                 outside the root
/// public/index.html
/// public/style.css
/// public/sub/index.html
/// public/sub/notes.txt
/// public/empty/              no index
/// public/inside -> style.css
/// public/leak -> ../secret.txt
/// public/.env                hidden files
/// public/.git/config
/// public/.well-known/index.html
/// public/sub/.hidden
/// ```
async fn with_tree(body : async (String) -> Unit) -> Unit {
  let dir = @fs.tmpdir(prefix="mttp-files-")
  let root = "\{dir}/public"
  @fs.write_text("\{dir}/secret.txt", "secret")
  @fs.mkdir(root)
  @fs.write_text("\{root}/index.html", "<h1>home</h1>")
  @fs.write_text("\{root}/style.css", "body{}")
  @fs.mkdir("\{root}/sub")
  @fs.write_text("\{root}/sub/index.html", "<h1>sub</h1>")
  @fs.write_text("\{root}/sub/notes.txt", "notes")
  @fs.mkdir("\{root}/empty")
  @fs.write_text("\{root}/.env", "TOKEN=secret")
  @fs.mkdir("\{root}/.git")
  @fs.write_text("\{root}/.git/config", "[core]")
  @fs.mkdir("\{root}/.well-known")
  @fs.write_text("\{root}/.well-known/index.html", "known")
  @fs.write_text("\{root}/sub/.hidden", "hidden")
  @fs.symlink(target="style.css", "\{root}/inside")
  @fs.symlink(target="../secret.txt", "\{root}/leak")
  defer @fs.rmdir(dir, recursive=true)
  body(root)
}

///|
async fn body_of(response : @mttp.Response) -> String {
  let bytes = match response.body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(stream) => @mttp.read_bounded(stream.take(), 1048576)
    @mttp.Body::.. => fail("unexpected body")
  }
  @utf8.decode(bytes)
}

///|
async fn expected_etag(path : String) -> String {
  let size = @fs.file_size(path)
  let mtime = @fs.mtime(path)
  "W/\"\{size.to_string(radix=16)}-\{mtime.sec().to_string(radix=16)}.\{mtime.nsec().to_string(radix=16)}\""
}

///|
async test "a file is served with its type, validators and cache policy" {
  with_tree(root => {
    let files = @files.static_files(root)
    let response = files(@mttp.Request::get("/style.css"))
    assert_eq(response.status, 200)
    assert_eq(
      response.headers.get("content-type"),
      Some("text/css; charset=utf-8"),
    )
    assert_eq(
      response.headers.get("etag"),
      Some(expected_etag("\{root}/style.css")),
    )
    let modified = @fs.mtime("\{root}/style.css").sec() * 1000L
    assert_eq(
      @mttp.parse_http_date(
        response.headers.get("last-modified").unwrap(),
        now_unix_ms=modified,
      ),
      Some(modified),
    )
    assert_eq(response.headers.get("cache-control"), Some("no-cache"))
    assert_eq(response.body.length(), Some(6L))
    assert_eq(body_of(response), "body{}")
    for path in ["/style.css#top", "/style.css?v=1#top", "/style.css?v=#1"] {
      assert_eq(body_of(files(@mttp.Request::get(path))), "body{}", msg=path)
    }
    // A root that is the file system's root still confines to itself.
    let everything = @files.static_files("/")
    assert_eq(
      body_of(everything(@mttp.Request::get("\{root}/style.css"))),
      "body{}",
    )
    let html = files(@mttp.Request::get("http://example.com/sub/notes.txt?v=2"))
    assert_eq(
      html.headers.get("content-type"),
      Some("text/plain; charset=utf-8"),
    )
    assert_eq(body_of(html), "notes")
    let cached = @files.static_files(root, cache_control="public, max-age=60")(
      @mttp.Request::get("/style.css"),
    )
    assert_eq(cached.headers.get("cache-control"), Some("public, max-age=60"))
    cached.close()
    let uncached = @files.static_files(root, cache_control="")(
      @mttp.Request::get("/style.css"),
    )
    assert_eq(uncached.headers.get("cache-control"), None)
    uncached.close()
  })
}

///|
async test "HEAD answers with the GET headers and no body" {
  with_tree(root => {
    let files = @files.static_files(root)
    let get = files(@mttp.Request::get("/style.css"))
    get.close()
    let head = files(@mttp.Request::new(Head, "/style.css"))
    assert_eq(head.status, 200)
    assert_eq(head.body, Empty)
    for name in ["content-type", "etag", "last-modified", "cache-control"] {
      assert_true(head.headers.get(name) is Some(_))
      assert_eq(head.headers.get(name), get.headers.get(name))
    }
  })
}

///|
async test "a matching If-None-Match is a 304 without a body" {
  with_tree(root => {
    let files = @files.static_files(root)
    let etag = expected_etag("\{root}/style.css")
    let strong = etag.clamped_view(start=2).to_owned()
    for field in [etag, strong, "\"other\", \{etag}", "*", "W/\"x\",\{strong}"] {
      let response = files(
        @mttp.Request::get("/style.css").header("if-none-match", field),
      )
      assert_eq(response.status, 304)
      assert_eq(response.body, Empty)
      assert_eq(response.headers.get("etag"), Some(etag))
      assert_eq(response.headers.get("cache-control"), Some("no-cache"))
    }
    let head = files(
      @mttp.Request::new(Head, "/style.css").header("if-none-match", etag),
    )
    assert_eq(head.status, 304)
    for field in ["\"other\"", "W/\"other\"", "", "nonsense, \{etag}", "\"open"] {
      let response = files(
        @mttp.Request::get("/style.css").header("if-none-match", field),
      )
      assert_eq(response.status, 200)
      assert_eq(body_of(response), "body{}")
    }
  })
}

///|
async test "a directory path ending in a slash serves its index and nothing else" {
  with_tree(root => {
    let files = @files.static_files(root)
    let home = files(@mttp.Request::get("/"))
    assert_eq(home.status, 200)
    assert_eq(
      home.headers.get("content-type"),
      Some("text/html; charset=utf-8"),
    )
    assert_eq(body_of(home), "<h1>home</h1>")
    assert_eq(
      body_of(files(@mttp.Request::get("http://example.com"))),
      "<h1>home</h1>",
    )
    assert_eq(body_of(files(@mttp.Request::get("/sub/"))), "<h1>sub</h1>")
    // No listing for a directory without an index, and a directory named
    // without the trailing slash is not served at all.
    for path in ["/empty/", "/sub", "/empty", "/missing.css", "/missing/"] {
      let response = files(@mttp.Request::get(path))
      assert_eq(response.status, 404)
      assert_eq(body_of(response), "Not Found\n")
    }
    let notes = @files.static_files(root, index="notes.txt")
    assert_eq(body_of(notes(@mttp.Request::get("/sub/"))), "notes")
    let none = @files.static_files(root, index="")
    assert_eq(none(@mttp.Request::get("/sub/")).status, 404)
    let escaping = @files.static_files(root, index="../secret.txt")
    assert_eq(escaping(@mttp.Request::get("/sub/")).status, 404)
  })
}

///|
async test "paths that could leave the root or alias a file are 404" {
  with_tree(root => {
    let files = @files.static_files(root)
    let paths = [
      // Dot segments, raw and encoded. The first stays inside the root once
      // normalized, so only refusing it (not normalizing it) gives 404.
      "/sub/../style.css",
      "http://example.com/sub/../style.css",
      "/../secret.txt",
      "/%2e%2e/secret.txt",
      "/%2E%2E/secret.txt",
      "/sub/%2e%2e/%2e%2e/secret.txt",
      "/./style.css",
      "/%2e/style.css",
      "/sub/.",
      // Empty segments and absolute-path tricks.
      "//style.css",
      "/sub//notes.txt",
      "http://example.com//style.css",
      "/%2Fstyle.css",
      "/sub%2Fnotes.txt",
      "/..%2Fsecret.txt",
      "/\{root}/style.css",
      // Backslashes, NUL and malformed escapes.
      "/sub%5Cnotes.txt",
      "/..%5Csecret.txt",
      "/sub\\notes.txt",
      "/C:%5Cstyle.css",
      "/style.css%00",
      "/style.css%00.png",
      "/%zz",
      "/style.css%",
      // Targets a file path cannot come from.
      "*",
      "example.com:80",
      "",
    ]
    for path in paths {
      let response = files(@mttp.Request::get(path))
      assert_eq(response.status, 404, msg="\{path}")
      assert_eq(body_of(response), "Not Found\n")
    }
    // The same file under a plain path is served.
    assert_eq(files(@mttp.Request::get("/sub/notes.txt")).status, 200)
  })
}

///|
async test "hidden files and directories are 404, raw or encoded" {
  with_tree(root => {
    let files = @files.static_files(root)
    let paths = [
      "/.env", "/%2eenv", "/%2Eenv", "/.git/config", "/%2egit/config", "/.git/",
      "/.well-known/", "/sub/.hidden", "/sub/%2ehidden", "http://example.com/.env",
    ]
    for path in paths {
      let response = files(@mttp.Request::get(path))
      assert_eq(response.status, 404, msg=path)
      assert_eq(body_of(response), "Not Found\n")
    }
    assert_eq(files(@mttp.Request::new(Head, "/.env")).status, 404)
    // The index option is held to the same rule.
    let hidden_index = @files.static_files(root, index=".hidden")
    assert_eq(hidden_index(@mttp.Request::get("/sub/")).status, 404)
    // A name with a dot elsewhere is an ordinary file.
    assert_eq(body_of(files(@mttp.Request::get("/sub/notes.txt"))), "notes")
  })
}

///|
async test "a symlink is served only when its target is below the root" {
  with_tree(root => {
    let files = @files.static_files(root)
    let inside = files(@mttp.Request::get("/inside"))
    assert_eq(inside.status, 200)
    assert_eq(body_of(inside), "body{}")
    let leak = files(@mttp.Request::get("/leak"))
    assert_eq(leak.status, 404)
    assert_eq(body_of(leak), "Not Found\n")
    // A root that is itself a symlink is resolved first, so its files stay
    // inside it.
    @fs.symlink(target=root, "\{root}/../linked")
    let linked = @files.static_files("\{root}/../linked")
    assert_eq(body_of(linked(@mttp.Request::get("/style.css"))), "body{}")
    assert_eq(linked(@mttp.Request::get("/leak")).status, 404)
  })
}

///|
async test "other methods are 405 with Allow, and the request body is closed" {
  with_tree(root => {
    let files = @files.static_files(root)
    for meth in [@mttp.Post, Put, Delete, Patch, Options] {
      let response = files(@mttp.Request::new(meth, "/style.css"))
      assert_eq(response.status, 405)
      assert_eq(response.headers.get("allow"), Some("GET, HEAD"))
      assert_eq(body_of(response), "Method Not Allowed\n")
    }
    assert_eq(files(@mttp.Request::post("/missing")).status, 405)
    let upload = UploadBody::{ closes: 0, }
    let response = files(
      @mttp.Request::post("/style.css").body_stream(upload, length=3L),
    )
    assert_eq(response.status, 405)
    assert_eq(upload.closes, 1)
  })
}

///|
priv struct UploadBody {
  mut closes : Int32
}

///|
impl @mttp.BodyStream for UploadBody with fn read_some(_) {
  raise @mttp.TransportError(
    kind=Invalid,
    phase=Body,
    detail="the file server read the request body",
  )
}

///|
impl @mttp.BodyStream for UploadBody with fn close(self) {
  self.closes += 1
}

///|
async test "only paths below the prefix are served" {
  with_tree(root => {
    for prefix in ["/assets/", "/assets", "assets"] {
      let files = @files.static_files(root, prefix~)
      assert_eq(
        body_of(files(@mttp.Request::get("/assets/style.css"))),
        "body{}",
      )
      assert_eq(
        body_of(files(@mttp.Request::get("/assets/%73tyle.css"))),
        "body{}",
      )
      assert_eq(body_of(files(@mttp.Request::get("/assets/"))), "<h1>home</h1>")
      for
        path in ["/style.css", "/assetsx/style.css", "/assets", "/", "/other/"] {
        assert_eq(files(@mttp.Request::get(path)).status, 404, msg="\{path}")
      }
      // Outside the prefix the method does not matter.
      assert_eq(files(@mttp.Request::post("/style.css")).status, 404)
      assert_eq(files(@mttp.Request::post("/assets/style.css")).status, 405)
    }
    let nested = @files.static_files(root, prefix="/a b/c/")
    assert_eq(
      body_of(nested(@mttp.Request::get("/a%20b/c/sub/notes.txt"))),
      "notes",
    )
  })
}

///|
async test "a missing root serves nothing" {
  let files = @files.static_files("/nonexistent/mttp-files-root")
  assert_eq(files(@mttp.Request::get("/")).status, 404)
  assert_eq(files(@mttp.Request::get("/style.css")).status, 404)
}

///|
async test "a large file streams in slices of at most 64 KiB" {
  with_tree(root => {
    let size = 65536 * 2 + 1
    @fs.write_binary(
      "\{root}/large.bin",
      Bytes::makei(size, i => (i % 251).to_byte()),
    )
    let response = @files.static_files(root)(@mttp.Request::get("/large.bin"))
    assert_eq(
      response.headers.get("content-type"),
      Some("application/octet-stream"),
    )
    guard response.body is Stream(stream) else { fail("not streamed") }
    assert_eq(stream.length(), Some(size.to_int64()))
    let reader = stream.take()
    let slices = []
    let mut offset = 0
    while reader.read_some() is Some(bytes) {
      assert_true(bytes.length() <= 65536)
      for i, byte in bytes {
        assert_eq(byte, ((offset + i) % 251).to_byte())
      }
      offset += bytes.length()
      slices.push(bytes.length())
    }
    assert_eq(offset, size)
    assert_eq(slices[0], 65536)
    assert_true(slices.length() >= 3)
    reader.close()
    // Closed early, a response's reader ends at once.
    let early = @files.static_files(root)(@mttp.Request::get("/large.bin"))
    guard early.body is Stream(stream) else { fail("not streamed") }
    let reader = stream.take()
    assert_true(reader.read_some() is Some(_))
    reader.close()
    assert_eq(reader.read_some(), None)
  })
}

///|
async test "a file that changes while served keeps the size it was opened with" {
  with_tree(root => {
    let files = @files.static_files(root)
    let grown = files(@mttp.Request::get("/style.css"))
    guard grown.body is Stream(stream) else { fail("not streamed") }
    @fs.write_text(
      "\{root}/style.css",
      "+more",
      create_mode=OpenExisting,
      append=true,
    )
    assert_eq(@utf8.decode(@mttp.read_bounded(stream.take(), 1024)), "body{}")
    let shrunk = files(@mttp.Request::get("/style.css"))
    guard shrunk.body is Stream(stream) else { fail("not streamed") }
    assert_eq(stream.length(), Some(11L))
    @fs.write_text("\{root}/style.css", "b")
    let result = Ok(@mttp.read_bounded(stream.take(), 1024)) catch {
      error => Err(error)
    }
    guard result is Err(@mttp.TransportError(kind=Protocol, ..)) else {
      fail("a short file was not reported")
    }
  })
}

///|
async test "the listener sends a file with its length and HEAD without a body" {
  with_tree(root => {
    let files = @files.static_files(root)
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let ready : Ref[String?] = Ref(None)
        let wake = @cond_var.Cond()
        group.spawn_bg(no_wait=true, () => {
          @server.serve(files, addr="127.0.0.1:0", on_listen=address => {
            ready.val = Some(address)
            wake.signal()
          })
        })
        while ready.val is None {
          wake.wait()
        }
        let address = ready.val.unwrap()
        let get = exchange(
          address, "GET /style.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        )
        assert_true(get.has_prefix("HTTP/1.1 200 OK\r\n"))
        assert_true(get.contains("\r\ncontent-length: 6\r\n"))
        assert_true(get.has_suffix("\r\n\r\nbody{}"))
        let head = exchange(
          address, "HEAD /style.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        )
        assert_true(head.has_prefix("HTTP/1.1 200 OK\r\n"))
        assert_true(head.contains("\r\netag: W/\""))
        assert_true(head.has_suffix("\r\n\r\n"))
        group.return_immediately()
      })
    })
  })
}

///|
async fn exchange(address : String, request : String) -> String {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
  defer tcp.close()
  tcp.write(@mttp.encode_utf8(request))
  @utf8.decode(tcp.read_all())
}
