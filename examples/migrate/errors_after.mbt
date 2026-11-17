///|
pub async fn errors_after(base : String) -> String {
  let api = @mttp.client(base_url=base)
  defer api.close()
  let reply = api.send(@mttp.get("/missing")) catch {
    @mttp.TransportError::TransportError(kind=Timeout(..), phase~, ..) =>
      return "timeout during \{Repr(phase)}"
    @mttp.TransportError::TransportError(..) as error => return error.message()
    error => raise error
  }
  match reply.body {
    Ok(text) => text
    Err(UnexpectedStatus(head, ..)) if head.status == 404 => "missing"
    Err(failure) => failure.to_string()
  }
}
