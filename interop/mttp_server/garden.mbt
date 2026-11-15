///|
/// h1's strings represent each wire octet by the same Latin-1 code point.
/// UTF-8 encoding would change obs-text, hiding precisely the differences
/// the Garden checks. Method, URL and protocol strings are ASCII here.
fn garden_base64(value : String) -> String {
  @base64.encode(Bytes::makei(value.length(), i => value[i].to_byte()))
}

///|
/// The handler receives an absolute URL, even for an origin-form target.
/// Strip the scheme and authority, without parsing the URL
/// again: Url::parse normalizes dot segments and would conceal differences.
fn garden_uri(url : String) -> String {
  let start = url.find("://").unwrap_or(-3) + 3
  for i in start..<url.length() {
    if url[i] == '/' {
      return url[i:].to_owned()
    }
    if url[i] == '?' {
      return "/" + url[i:].to_owned()
    }
  }
  "/"
}

///|
async fn garden(request : @mttp_core.Request) -> @mttp_core.Response noraise {
  let body = request.body.read_all(max=max_body) catch {
    _ => return text(400, "invalid request body\n")
  }
  let headers = request.headers
    .iter()
    .map(pair => {
      Json::array([
        Json::string(garden_base64(pair.0)),
        Json::string(garden_base64(pair.1)),
      ])
    })
    .to_array()
  let protocol = request.attributes
    .get(@mttp_core.protocol)
    .unwrap_or("http/1.1")
  let result : Json = {
    "headers": Json::array(headers),
    "body": @base64.encode(body),
    "method": garden_base64(request.meth.to_string()),
    "version": garden_base64(protocol["http/".length():].to_owned()),
    "uri": garden_base64(garden_uri(request.url)),
  }
  @mttp_core.Response::new(
    200,
    headers=@mttp_core.Headers::of([("Content-Type", "application/json")]),
    body=Bytes(@mttp_core.encode_utf8(result.stringify())),
  )
}
