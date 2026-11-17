///|
pub async fn tls_before(origin : String, pem : String) -> Bytes {
  let conn = @http.ClientConnection(origin, trust=CustomPemFile(pem))
  defer conn.close()
  conn.request(Get, "/")
  ignore(conn.end_request())
  conn.read_all()
}
