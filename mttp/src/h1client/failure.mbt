///|
/// `error` as a TransportError of `phase`: a TransportError keeps its kind
/// and its phase unless that is `Unknown`, a codec error is `Protocol`, and
/// anything else a port raised is `Connect` while dialling and `Network`
/// otherwise. Cancellation is not an `Error` and never reaches this.
fn failure(phase : @mttp.Phase, error : Error) -> @mttp.TransportError {
  match error {
    @mttp.TransportError(kind~, phase=Unknown, detail~) =>
      @mttp.TransportError(kind~, phase~, detail~)
    @mttp.TransportError(..) as error => error
    @h1.ParseError(detail~, ..) =>
      @mttp.TransportError(kind=Protocol, phase~, detail~)
    _ =>
      @mttp.TransportError(
        kind=if phase == Dial { Connect } else { Network },
        phase~,
        detail=error.to_string(),
      )
  }
}

///|
fn invalid(detail : String) -> @mttp.TransportError {
  @mttp.TransportError(kind=Invalid, phase=Pool, detail~)
}

///|
fn closed() -> @mttp.TransportError {
  @mttp.TransportError(kind=Closed, phase=Pool, detail="client closed")
}
