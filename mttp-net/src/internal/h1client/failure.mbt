///|
pub fn failure(phase : @model.Phase, error : Error) -> @model.TransportError {
  match error {
    @model.TransportError(kind~, phase=Unknown, detail~) =>
      @model.TransportError(kind~, phase~, detail~)
    @model.TransportError(..) as error => error
    @h1.ParseError(..) =>
      @model.TransportError(kind=Protocol, phase~, detail=error.to_string())
    _ =>
      @model.TransportError(
        kind=if phase == Dial { Connect } else { Network },
        phase~,
        detail=error.to_string(),
      )
  }
}
