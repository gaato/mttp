///|
/// Server hand-over after a validated 101 head. The HTTP engine joins its
/// reader before calling this with every byte read past the request head.
/// The connection remains admitted until return; stopping reports shutdown.
pub let upgrade : @mttp_core.AttributeKey[
  async (&Conn, Bytes, () -> Bool) -> Unit noraise,
] = @mttp_core.AttributeKey::new("upgrade")
