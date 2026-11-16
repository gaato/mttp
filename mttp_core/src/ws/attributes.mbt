///|
/// Client-role session supplied by an in-process or message-level backend.
/// The caller owns it and must close or abort it, independently of the body.
pub let ws_session : @mttp_core.AttributeKey[&Session] = @mttp_core.AttributeKey::new(
  "ws_session",
)
