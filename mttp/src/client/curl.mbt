///|
fn shell_quote(value : String) -> String {
  "'" + value.replace_all(old="'", new="'\\''") + "'"
}

///|
fn printf_bytes(bytes : Bytes) -> String {
  let out = StringBuilder()
  for byte in bytes {
    let n = byte.to_int()
    out.write_string("\\0")
    for shift in [6, 3, 0] {
      out.write_char((48 + ((n >> shift) & 7)).unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// Renders a POSIX-shell curl diagnostic for the raw request, before Client
/// defaults, cookies, retries or redirects. Sensitive header names are matched
/// case-insensitively. URL userinfo is redacted; query strings and byte bodies
/// are not. Set include_body=false to omit byte bodies as well.
///
/// Byte bodies use a quoted printf pipeline so NUL, quotes, newlines and an
/// initial @ remain bytes rather than shell syntax or a curl filename. Stream
/// bodies and body factories are never consumed/invoked; a comment marks their
/// omission. This function does not execute the command or validate the URL.
pub fn[T] ClientRequest::to_curl(
  self : ClientRequest[T],
  sensitive_headers~ : Array[String] = [
    "authorization", "proxy-authorization", "cookie", "x-api-key", "api-key",
  ],
  include_body~ : Bool = true,
) -> String {
  let request = self.raw
  let sensitive = sensitive_headers.map(String::to_lower)
  let args = [
    "curl",
    "--globoff",
    "--request",
    shell_quote(request.meth.to_string()),
  ]
  for (name, value) in request.headers.iter() {
    args.push("--header")
    args.push(
      shell_quote(
        name +
        ": " +
        (if sensitive.contains(name.to_lower()) { "<redacted>" } else { value }),
      ),
    )
  }
  let parsed = Some(@model.Url::parse(request.url)) catch { _ => None }
  let url = match parsed {
    Some(url) if url.userinfo is Some(_) => "<URL userinfo redacted>"
    _ => request.url
  }
  args.push("--url")
  args.push(shell_quote(url))
  let mut prefix = ""
  let mut comment = ""
  if self.body_factory is Some(_) {
    comment = " # body factory omitted"
  } else {
    match request.body {
      Empty => ()
      Bytes(bytes) =>
        if include_body {
          prefix = "printf '%b' " + shell_quote(printf_bytes(bytes)) + " | "
          args.push("--data-binary")
          args.push("@-")
          if !request.headers.contains("content-type") {
            args.push("--header")
            args.push("'content-type:'")
          }
        } else {
          comment = " # byte body omitted"
        }
      Stream(_) => comment = " # streaming body omitted"
    }
  }
  prefix + args.join(" ") + comment
}
