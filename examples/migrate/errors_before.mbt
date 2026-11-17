///|
pub async fn errors_before(base : String) -> String {
  let (head, body) = @http.get(base + "/missing") catch {
    @http.UriParseError::_ => return "invalid URL"
    _ => return "request failed"
  }
  if head.code == 404 {
    "missing"
  } else {
    body.text()
  }
}
