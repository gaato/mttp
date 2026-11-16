///|
/// The trace id of the W3C `traceparent` a request went out with, as 32
/// lowercase hex digits: set by `trace_context` on the response, both for
/// the header it added and for a valid one the request already had.
pub let trace_id : @mttp_core.AttributeKey[String] = @mttp_core.AttributeKey::new(
  "client.trace_id",
)

///|
priv struct TraceContext {
  inner : &@mttp_core.Backend
  generate : () -> Double
  mut closed : Bool
}

///|
/// Wraps `inner` so that each request carries W3C Trace Context
/// (https://www.w3.org/TR/trace-context/): a request without `traceparent`
/// gets `00-<trace id>-<span id>-01`, a new random 16-byte trace id and
/// 8-byte span id in lowercase hex, sampled, and a request that has one
/// keeps it unchanged. The response carries the trace id under `trace_id`
/// (none when the request's own header is not a valid traceparent);
/// other response attributes pass through.
///
/// The ids come from `generate`, which returns numbers in [0, 1) like
/// `Client::new`'s `random`; each call supplies 32 bits. An id that would
/// be all zeros, which W3C forbids, ends in 1 instead.
///
/// Placed under a `Client`, every exchange it sends (each retry and each
/// redirect hop) starts its own trace; set `traceparent` on the request to
/// keep them in the caller's trace.
///
/// ```mbt check
/// test {
///   let backend = @client.trace_context(
///     @client.from_fn((request, _) => {
///       @mttp_core.Response::new(200, headers=request.headers)
///     }),
///     generate=() => 0.5,
///   )
///   @driver.run_sync(() => {
///     let response = backend.send(
///       @mttp_core.Request::get("https://example.test/"),
///       @mttp_core.SendOptions::default(),
///     )
///     assert_eq(
///       response.headers.get("traceparent"),
///       Some("00-80000000800000008000000080000000-8000000080000000-01"),
///     )
///     assert_eq(
///       response.attributes.get(@client.trace_id),
///       Some("80000000800000008000000080000000"),
///     )
///   })
/// }
/// ```
pub fn trace_context(
  inner : &@mttp_core.Backend,
  generate~ : () -> Double = @rt.default_random,
) -> &@mttp_core.Backend {
  TraceContext::{ inner, generate, closed: false, }
}

///|
impl @mttp_core.Backend for TraceContext with fn send(self, request, options) {
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="trace context backend is closed",
    )
  }
  request.validate()
  options.validate()
  let existing = request.headers.get_all("traceparent")
  let (request, id) = if existing.is_empty() {
    let id = random_hex(self.generate, 16)
    let span = random_hex(self.generate, 8)
    (request.header("traceparent", "00-\{id}-\{span}-01"), Some(id))
  } else if existing.length() == 1 {
    (request, traceparent_trace_id(existing[0]))
  } else {
    (request, None)
  }
  let response = self.inner.send(request, options)
  match id {
    Some(id) =>
      { ..response, attributes: response.attributes.put(trace_id, id), }
    None => response
  }
}

///|
impl @mttp_core.Backend for TraceContext with fn close(self) {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}

///|
let hex_digits : String = "0123456789abcdef"

///|
/// `bytes` (a multiple of 4) random bytes in lowercase hex, 32 bits per
/// call of `generate`, never all zeros.
fn random_hex(generate : () -> Double, bytes : Int32) -> String {
  let out = StringBuilder()
  let mut zero = true
  for _ in 0..<(bytes / 4) {
    let sample = generate()
    let sample = if sample.is_nan() || sample < 0.0 {
      0.0
    } else if sample >= 1.0 {
      0.9999999999
    } else {
      sample
    }
    let word = (sample * 4294967296.0).to_uint64() & 0xFFFFFFFFUL
    if word != 0UL {
      zero = false
    }
    for shift = 28; shift >= 0; shift = shift - 4 {
      out.write_char(
        hex_digits.get_char(((word >> shift) & 0xFUL).to_int()).unwrap(),
      )
    }
  }
  let hex = out.to_string()
  if zero {
    hex[:hex.length() - 1].to_owned() + "1"
  } else {
    hex
  }
}

///|
/// The trace id of a valid `traceparent` value (W3C Trace Context, section
/// 3.2): version, trace id, parent id and flags in lowercase hex, a version
/// other than `ff`, ids not all zeros, and for version 00 nothing more.
fn traceparent_trace_id(value : String) -> String? {
  let parts = value
    .trim(chars=" \t")
    .split("-")
    .map(p => p.to_owned())
    .to_array()
  guard parts is [version, id, parent, flags, ..] &&
    lower_hex(version, 2) &&
    version != "ff" &&
    lower_hex(id, 32) &&
    lower_hex(parent, 16) &&
    lower_hex(flags, 2) &&
    !all_zero(id) &&
    !all_zero(parent) &&
    (parts.length() == 4 || version != "00") else {
    return None
  }
  Some(id)
}

///|
fn lower_hex(text : String, length : Int32) -> Bool {
  text.length() == length &&
  text.iter().all(c => c is ('0'..<='9' | 'a'..<='f'))
}

///|
fn all_zero(text : String) -> Bool {
  text.iter().all(c => c == '0')
}
