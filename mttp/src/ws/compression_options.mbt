///|
/// Opt-in RFC 7692 compression. Both directions request no context takeover
/// by default. JS hosts own compression; this option has no effect there.
pub struct Compression {
  priv server_no_context_takeover : Bool
  priv client_no_context_takeover : Bool
}

///|
/// Window size is fixed at 15 for encoding; decoding accepts windows 8–15.
pub fn Compression::new(
  server_no_context_takeover~ : Bool = true,
  client_no_context_takeover~ : Bool = true,
) -> Compression {
  { server_no_context_takeover, client_no_context_takeover, }
}

///|
fn Compression::offer(self : Compression) -> String {
  "permessage-deflate; client_max_window_bits" +
  (if self.server_no_context_takeover {
    "; server_no_context_takeover"
  } else {
    ""
  }) +
  (if self.client_no_context_takeover {
    "; client_no_context_takeover"
  } else {
    ""
  })
}
