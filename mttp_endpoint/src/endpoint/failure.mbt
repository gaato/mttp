///|
fn missing() -> @schema.DecodeFailure {
  @schema.DecodeFailure(kind=Missing, message="required input is missing")
}

///|
fn multiple(count : Int32) -> @schema.DecodeFailure {
  @schema.DecodeFailure(
    kind=Multiple(count),
    message="expected one input value",
  )
}

///|
fn mismatch(expected : String) -> @schema.DecodeFailure {
  @schema.DecodeFailure(
    kind=Mismatch(expected~, actual="other scheme"),
    message="unexpected authentication scheme",
  )
}

///|
fn unsupported_media_type(actual : String) -> @schema.DecodeFailure {
  @schema.DecodeFailure(
    kind=UnsupportedMediaType(actual),
    message="unsupported content type",
  )
}
