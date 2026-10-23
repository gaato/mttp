///|
priv struct Rule {
  matches : (@model.Request) -> Bool
  respond : async (@model.Request, @client.RequestOptions) -> @model.Response raise @model.TransportError
}

///|
/// sttp-style `when` rules (FakeTransport's strict FIFO expect API is
/// moved alongside in the real package).
pub struct BackendStub {
  priv rules : Array[Rule]
  priv sent : Array[@model.Request]
}

///|
pub fn BackendStub::new() -> BackendStub {
  { rules: [], sent: [] }
}

///|
/// `respond` receives the RequestOptions, so bounds (max_body_bytes) apply.
pub fn BackendStub::when(
  self : BackendStub,
  matches : (@model.Request) -> Bool,
  respond : async (@model.Request, @client.RequestOptions) -> @model.Response raise @model.TransportError,
) -> BackendStub {
  self.rules.push({ matches, respond })
  self
}

///|
pub fn BackendStub::sent(self : BackendStub) -> Array[@model.Request] {
  self.sent
}

///|
pub impl @client.Backend for BackendStub with send(self, req, opts) {
  self.sent.push(req)
  for r in self.rules {
    if (r.matches)(req) {
      return (r.respond)(req, opts)
    }
  }
  raise @model.TransportError(kind=Connect, phase=Dial, detail="no stub rule for \{req.meth} \{req.url}")
}
