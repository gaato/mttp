///|
/// `error` as a TransportError of `phase`: a TransportError keeps its kind
/// and its phase unless that is `Unknown`, a codec error is `Protocol`, and
/// anything else a port raised is `Connect` while dialling and `Network`
/// otherwise. Cancellation is not an `Error` and never reaches this.
fn failure(phase : @http.Phase, error : Error) -> @http.TransportError {
  match error {
    @http.TransportError(kind~, phase=Unknown, detail~) =>
      @http.TransportError(kind~, phase~, detail~)
    @http.TransportError(..) as error => error
    @h1.ParseError(detail~, ..) =>
      @http.TransportError(kind=Protocol, phase~, detail~)
    _ =>
      @http.TransportError(
        kind=if phase == Dial { Connect } else { Network },
        phase~,
        detail=error.to_string(),
      )
  }
}

///|
fn invalid(detail : String) -> @http.TransportError {
  @http.TransportError(kind=Invalid, phase=Pool, detail~)
}

///|
fn closed() -> @http.TransportError {
  @http.TransportError(kind=Closed, phase=Pool, detail="client closed")
}
