///|
/// A response plan. Byte responses can be reused; factories must return a
/// fresh stream for each send so take-once state is never shared accidentally.
#non_exhaustive
pub(all) enum Canned {
  Response(status~ : Int32, headers~ : @model.Headers, body~ : Bytes)
  Failure(@model.TransportError)
  Factory(@client.SendFn)
}

///|
/// Builds a reusable byte response, defaulting to empty headers and body.
pub fn Canned::bytes(
  status : Int32,
  body~ : Bytes = b"",
  headers~ : @model.Headers = @model.Headers::empty(),
) -> Canned {
  Response(status~, headers~, body~)
}

///|
async fn Canned::respond(
  self : Canned,
  request : @model.Request,
  options : @client.RequestOptions,
) -> @model.Response raise @model.TransportError {
  match self {
    Response(status~, headers~, body~) =>
      @model.Response::new(status, headers~, body=Bytes(body))
    Failure(error) => raise error
    Factory(factory) => factory(request, options)
  }
}

///|
/// An immutable record of one attempted send. Streaming request bodies are
/// recorded as None without consuming them; byte bodies are captured by value.
pub(all) struct Recorded {
  request : @model.RequestHead
  options : @client.RequestOptions
  body : Bytes?
} derive(Eq, Debug)

///|
/// Compares recorded request metadata, options and buffered bytes.
pub extend Recorded with Eq::{equal, not_equal}

///|
/// Formats a recorded request for assertions.
pub extend Recorded with @debug.Debug::{to_repr}

///|
priv struct Rule {
  matches : (@model.Request) -> Bool
  response : Canned
}

///|
/// A strict FIFO expectation queue followed by reusable predicate rules.
/// An unmatched send is a Protocol failure, never a retryable connection error.
pub struct BackendStub {
  priv expected : Array[Rule]
  priv rules : Array[Rule]
  priv records : Array[Recorded]
  priv mut next : Int32
  priv mut closed : Bool
}

///|
/// Creates an empty, strict stub.
pub fn BackendStub::new() -> BackendStub {
  { expected: [], rules: [], records: [], next: 0, closed: false, }
}

///|
/// Appends a one-shot expectation. A mismatch does not consume it.
pub fn BackendStub::expect(
  self : BackendStub,
  matches : (@model.Request) -> Bool,
  response : Canned,
) -> BackendStub {
  self.expected.push({ matches, response, })
  self
}

///|
/// Adds a reusable rule, evaluated in registration order after expectations.
pub fn BackendStub::when(
  self : BackendStub,
  matches : (@model.Request) -> Bool,
  response : Canned,
) -> BackendStub {
  self.rules.push({ matches, response, })
  self
}

///|
/// Returns an independent array of request records.
pub fn BackendStub::sent(self : BackendStub) -> Array[Recorded] {
  self.records.copy()
}

///|
/// Returns the number of unconsumed FIFO expectations.
pub fn BackendStub::remaining(self : BackendStub) -> Int32 {
  self.expected.length() - self.next
}

///|
/// Reports unconsumed expectations using a test failure rather than aborting.
pub fn BackendStub::verify(self : BackendStub) -> Unit raise {
  if self.remaining() != 0 {
    fail("\{self.remaining()} unconsumed backend expectations")
  }
}

///|
/// Validates, records and responds to one send. An unexpected send is terminal.
pub impl @client.Backend for BackendStub with fn send(self, request, options) {
  if self.closed {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="stub is closed",
    )
  }
  request.validate()
  self.records.push({
    request: request.head(),
    options,
    body: request.body.as_bytes(),
  })
  if self.next < self.expected.length() {
    let rule = self.expected[self.next]
    if !(rule.matches)(request) {
      raise @model.TransportError(
        kind=Protocol,
        phase=Unknown,
        detail="stub FIFO expectation did not match",
      )
    }
    self.next += 1
    return rule.response.respond(request, options)
  }
  for rule in self.rules {
    if (rule.matches)(request) {
      return rule.response.respond(request, options)
    }
  }
  raise @model.TransportError(
    kind=Protocol,
    phase=Unknown,
    detail="no stub rule matched request",
  )
}

///|
/// Closes the stub; future sends fail without recording or matching.
pub impl @client.Backend for BackendStub with fn close(self) {
  self.closed = true
}

///|
/// Exposes backend operations on the concrete stub.
pub extend BackendStub with @client.Backend::{send, close}
