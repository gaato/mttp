///|
/// What a stub answers. Byte responses can be reused; factories must return a
/// fresh stream for each send so take-once state is never shared accidentally.
/// A canned response or failure closes a stream request body unread, as a
/// backend must; a factory receives the request and owns its body.
#non_exhaustive
pub(all) enum Canned {
  Response(status~ : Int32, headers~ : @mttp.Headers, body~ : Bytes)
  Failure(@mttp.TransportError)
  Factory(
    async (@mttp.Request, @mttp.SendOptions) -> @mttp.Response raise @mttp.TransportError
  )
}

///|
/// Builds a reusable byte response, defaulting to empty headers and body.
pub fn Canned::bytes(
  status : Int32,
  body~ : Bytes = b"",
  headers~ : @mttp.Headers = @mttp.Headers::empty(),
) -> Canned {
  Response(status~, headers~, body~)
}

///|
async fn Canned::respond(
  self : Canned,
  request : @mttp.Request,
  options : @mttp.SendOptions,
) -> @mttp.Response raise @mttp.TransportError {
  match self {
    Response(status~, headers~, body~) => {
      close_body(request)
      @mttp.Response::new(status, headers~, body=Bytes(body))
    }
    Failure(error) => {
      close_body(request)
      raise error
    }
    Factory(factory) => factory(request, options)
  }
}

///|
/// Closes a stream request body nobody will read, as a backend must.
fn close_body(request : @mttp.Request) -> Unit {
  if request.body is Stream(stream) {
    stream.close()
  }
}

///|
/// An immutable record of one attempted send. Streaming request bodies are
/// recorded as None without consuming them; byte bodies are captured by value.
#derive(Eq, Debug)
pub(all) struct Recorded {
  request : @mttp.RequestHead
  options : @mttp.SendOptions
  body : Bytes?
}

///|
/// Compares recorded request metadata, options and buffered bytes.
pub extend Recorded with Eq::{equal, not_equal}

///|
/// Formats a recorded request for assertions.
pub extend Recorded with @debug.Debug::{to_repr}

///|
priv struct Rule {
  matches : (@mttp.Request) -> Bool
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
  matches : (@mttp.Request) -> Bool,
  response : Canned,
) -> BackendStub {
  self.expected.push({ matches, response, })
  self
}

///|
/// Adds a reusable rule, evaluated in registration order after expectations.
pub fn BackendStub::when(
  self : BackendStub,
  matches : (@mttp.Request) -> Bool,
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
pub impl @mttp.Backend for BackendStub with fn send(self, request, options) {
  if self.closed {
    raise @mttp.TransportError(kind=Closed, phase=Pool, detail="stub is closed")
  }
  request.validate()
  options.validate()
  self.records.push({
    request: request.head(),
    options,
    body: request.body.as_bytes(),
  })
  if self.next < self.expected.length() {
    let rule = self.expected[self.next]
    if !(rule.matches)(request) {
      close_body(request)
      raise @mttp.TransportError(
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
  close_body(request)
  raise @mttp.TransportError(
    kind=Protocol,
    phase=Unknown,
    detail="no stub rule matched request",
  )
}

///|
/// Closes the stub; future sends fail without recording or matching.
pub impl @mttp.Backend for BackendStub with fn close(self) {
  self.closed = true
}

///|
/// Exposes backend operations on the concrete stub.
pub extend BackendStub with @mttp.Backend::{send, close}
