///|
/// `error` as a TransportError of `phase`: a TransportError keeps its kind
/// and its phase unless that is `Unknown`, a codec error is `Protocol`, and
/// anything else a port raised is `Connect` while dialling and `Network`
/// otherwise. Cancellation is not an `Error` and never reaches this.
fn failure(
  phase : @mttp_core.Phase,
  error : Error,
) -> @mttp_core.TransportError {
  match error {
    @mttp_core.TransportError(kind~, phase=Unknown, detail~) =>
      @mttp_core.TransportError(kind~, phase~, detail~)
    @mttp_core.TransportError(..) as error => error
    @h1.ParseError(detail~, ..) =>
      @mttp_core.TransportError(kind=Protocol, phase~, detail~)
    _ =>
      @mttp_core.TransportError(
        kind=if phase == Dial { Connect } else { Network },
        phase~,
        detail=error.to_string(),
      )
  }
}

///|
fn invalid(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Invalid, phase=Pool, detail~)
}

///|
fn closed() -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Closed, phase=Pool, detail="client closed")
}
