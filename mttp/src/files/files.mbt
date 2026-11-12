///|
/// The most bytes read from a file for one pull of a served body: memory per
/// streamed response does not grow with the file.
const CHUNK_BYTES : Int32 = 65536

///|
/// A Handler that serves the files below `root` to GET and HEAD requests
/// whose decoded path lies below `prefix`.
///
/// - The path below `prefix` names a file below `root`. A path ending in `/`
///   names a directory and serves its `index` file (`""` serves none);
///   directories are never listed, and a directory named without the
///   trailing slash is a 404, as is the prefix itself without one.
/// - A segment that starts with `.` once decoded (so `.`, `..` and hidden
///   files such as `.env` or `.git`), contains `/`, `\` or NUL, or is empty
///   (other than a final one) is a 404, raw or percent-encoded. The
///   file's real path, with every symlink resolved, must lie below `root`'s
///   real path, so a symlink is served only when its target is below `root`.
///   Only regular files are opened.
/// - Other methods under `prefix` are 405 with `Allow: GET, HEAD`; a path
///   outside `prefix` is a 404 whatever the method.
/// - A 200 carries `Content-Type` from the extension, a weak `ETag` from the
///   size and modification time, `Last-Modified` and `Cache-Control` (left
///   out when `cache_control` is `""`). A matching `If-None-Match` is a 304
///   without a body. Ranges are not supported: a GET is always the whole
///   file, read in slices of at most 64 KiB as the connection pulls them.
///
/// Failures say nothing about the file system: every refusal and lookup
/// failure is the same plain 404.
///
/// ```mbt check
/// async test "static_files refuses a path that leaves the root" {
///   let assets = @files.static_files("public", prefix="/assets/")
///   let response = assets(@mttp_core.Request::get("/assets/../secret.txt"))
///   assert_eq(response.status, 404)
/// }
/// ```
pub fn static_files(
  root : String,
  prefix~ : String = "/",
  cache_control~ : String = "no-cache",
  index~ : String = "index.html",
) -> @mttp_core.Handler {
  let mount = mount_segments(prefix)
  async fn(request) noraise {
    serve(root, mount, cache_control, index, request)
  }
}

///|
/// The decoded segments of a prefix. Empty components are dropped, so `/a`,
/// `/a/` and `a` mean the same.
fn mount_segments(prefix : String) -> Array[String] {
  prefix
  .split("/")
  .filter(part => !part.is_empty())
  .map(part => part.to_owned())
  .collect()
}

///|
priv suberror NotServed

///|
async fn serve(
  root : String,
  mount : Array[String],
  cache_control : String,
  index : String,
  request : @mttp_core.Request,
) -> @mttp_core.Response noraise {
  // A handler owns its request body; a file server never reads one.
  if request.body is Stream(stream) {
    stream.close()
  }
  guard request_segments(request.url) is Some((segments, directory)) &&
    segments.length() >= mount.length() &&
    segments[:mount.length()] == mount[:] else {
    return plain(404)
  }
  match request.meth {
    Get | Head => ()
    _ => {
      let refused = plain(405)
      return { ..refused, headers: refused.headers.set("allow", "GET, HEAD"), }
    }
  }
  let names = segments[mount.length():].to_owned()
  if directory {
    guard safe_segment(index) else { return plain(404) }
    names.push(index)
  }
  guard !names.is_empty() else { return plain(404) }
  let file = open_below(root, names) catch { _ => return plain(404) }
  let (size, mtime) = (file.size(), file.mtime()) catch {
    _ => {
      file.close()
      return plain(500)
    }
  }
  let etag = "W/\"\{size.to_string(radix=16)}-\{mtime.sec().to_string(radix=16)}.\{mtime.nsec().to_string(radix=16)}\""
  let mut validators = @mttp_core.Headers::of([("etag", etag)])
  if !cache_control.is_empty() {
    validators = validators.set("cache-control", cache_control)
  }
  if request.headers
    .get_all("if-none-match")
    .iter()
    .any(field => matches(field, etag)) {
    file.close()
    return @mttp_core.Response::new(304, headers=validators)
  }
  let headers = validators
    .set("content-type", content_type(names[names.length() - 1]))
    .set("last-modified", @mttp_core.format_http_date(mtime.msec()))
  if request.meth is Head {
    file.close()
    return @mttp_core.Response::new(200, headers~)
  }
  @mttp_core.Response::new(
    200,
    headers~,
    body=Stream(
      @mttp_core.StreamBody::new(
        FileBody::{ file, remaining: size, buffer: None, closed: false, },
        length=size,
      ),
    ),
  )
}

///|
/// Opens `names` below `root` for reading, refusing anything whose real path
/// is not below `root`'s real path and anything but a regular file.
async fn open_below(root : String, names : Array[String]) -> @fs.File {
  let base = @fs.realpath(root)
  let target = @fs.realpath(below(base, "/") + names.join("/"))
  // Only the platform's separator ends a component: on POSIX a backslash is
  // an ordinary character, so `/srv/public\x` is a sibling of `/srv/public`.
  guard target == base || target.has_prefix(below(base, @path.sep.to_string())) else {
    raise NotServed
  }
  // Checked before opening, which would wait for a writer on a FIFO.
  guard @fs.kind(target, follow_symlink=false) is Regular else {
    raise NotServed
  }
  let file = @fs.open(target, mode=ReadOnly)
  guard file.kind() is Regular else {
    file.close()
    raise NotServed
  }
  file
}

///|
fn below(base : String, separator : String) -> String {
  if base.has_suffix(separator) {
    base
  } else {
    base + separator
  }
}

///|
/// The decoded segments of the request's path and whether it ends in `/`.
/// `None` for anything a file path cannot be built from safely.
fn request_segments(url : String) -> (Array[String], Bool)? {
  guard raw_path(url) is Some(path) else { return None }
  let parts = path.clamped_view(start=1).split("/").collect()
  let directory = parts[parts.length() - 1].is_empty()
  if directory {
    parts.pop() |> ignore
  }
  let segments = []
  for part in parts {
    let name = @mttp_core.percent_decode(part.to_owned()) catch {
      _ => return None
    }
    guard safe_segment(name) else { return None }
    segments.push(name)
  }
  Some((segments, directory))
}

///|
/// The path of an origin-form or absolute URL as sent, before any dot
/// segment is removed, without the query or fragment; `/` for an absolute
/// URL without a path.
fn raw_path(url : String) -> String? {
  let end = match (url.find("?"), url.find("#")) {
    (Some(q), Some(f)) => q.min(f)
    (Some(q), None) => q
    (None, Some(f)) => f
    (None, None) => url.length()
  }
  let target = url.clamped_view(end~)
  if target.has_prefix("/") {
    return Some(target.to_owned())
  }
  guard target.find("://") is Some(scheme) else { return None }
  let authority = target.clamped_view(start=scheme + 3)
  match authority.find("/") {
    Some(slash) => Some(authority.clamped_view(start=slash).to_owned())
    None => Some("/")
  }
}

///|
/// A name a file path may be built from. A leading `.` covers `.` and
/// `..` and also refuses hidden files, such as `.git` or `.env` left in a
/// deployed directory.
fn safe_segment(name : String) -> Bool {
  !name.is_empty() &&
  !name.has_prefix(".") &&
  !name.contains("/") &&
  !name.contains("\\") &&
  !name.contains("\u{0}")
}

///|
/// Whether an `If-None-Match` field value matches `etag` under the weak
/// comparison (RFC 9110, section 13.1.2). A malformed list matches nothing
/// past the malformed element.
fn matches(field : String, etag : String) -> Bool {
  let tag = etag.clamped_view(start=2).to_owned()
  let chars = field.to_array()
  let n = chars.length()
  let mut i = 0
  while i < n {
    match chars[i] {
      ' ' | '\t' | ',' => {
        i += 1
        continue
      }
      '*' => return true
      'W' if i + 1 < n && chars[i + 1] == '/' => i += 2
      _ => ()
    }
    guard i < n && chars[i] == '"' else { return false }
    let start = i
    i += 1
    while i < n && chars[i] != '"' {
      i += 1
    }
    guard i < n else { return false }
    i += 1
    if String::from_array(chars[start:i]) == tag {
      return true
    }
  }
  false
}

///|
/// The media type of a file name, from its extension, ignoring case.
fn content_type(name : String) -> String {
  let extension = match name.rev_find(".") {
    Some(dot) if dot > 0 => name.clamped_view(start=dot + 1).to_lower()
    _ => ""
  }
  match extension {
    "html" | "htm" => "text/html; charset=utf-8"
    "css" => "text/css; charset=utf-8"
    "js" | "mjs" => "text/javascript; charset=utf-8"
    "txt" => "text/plain; charset=utf-8"
    "json" | "map" => "application/json"
    "svg" => "image/svg+xml"
    "png" => "image/png"
    "jpg" | "jpeg" => "image/jpeg"
    "gif" => "image/gif"
    "webp" => "image/webp"
    "ico" => "image/x-icon"
    "wasm" => "application/wasm"
    "woff2" => "font/woff2"
    _ => "application/octet-stream"
  }
}

///|
fn plain(status : Int32) -> @mttp_core.Response {
  @mttp_core.Response::new(
    status,
    headers=@mttp_core.Headers::of([
      ("content-type", "text/plain; charset=utf-8"),
    ]),
    body=Bytes(@mttp_core.encode_utf8("\{@mttp_core.reason_phrase(status)}\n")),
  )
}

///|
/// A file's bytes, at most `remaining` of them, in slices of at most
/// `CHUNK_BYTES`; the file is closed at the end, on failure and on close.
priv struct FileBody {
  file : @fs.File
  mut remaining : Int64
  mut buffer : FixedArray[Byte]?
  mut closed : Bool
}

///|
impl @mttp_core.BodyStream for FileBody with fn read_some(self) {
  if self.closed {
    return None
  }
  guard self.remaining > 0L else {
    @mttp_core.BodyStream::close(self)
    return None
  }
  let want = if self.remaining < CHUNK_BYTES.to_int64() {
    self.remaining.to_int()
  } else {
    CHUNK_BYTES
  }
  let buffer = match self.buffer {
    Some(buffer) => buffer
    None => {
      let buffer = FixedArray::make(want, b'\x00')
      self.buffer = Some(buffer)
      buffer
    }
  }
  let n = self.file.read_into(buffer, max_len=want) catch {
    error => {
      @mttp_core.BodyStream::close(self)
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Body,
        detail="reading the served file failed: \{(error : Error)}",
      )
    }
  }
  // A file that shrank ends early; the declared length reports it.
  guard n > 0 else {
    @mttp_core.BodyStream::close(self)
    return None
  }
  self.remaining -= n.to_int64()
  Some(Bytes::from_array(buffer[:n]))
}

///|
impl @mttp_core.BodyStream for FileBody with fn close(self) {
  if !self.closed {
    self.closed = true
    self.buffer = None
    self.file.close()
  }
}
