///|
/// Message documentation retained beside the handshake, for future AsyncAPI
/// projection. Directions are always relative to the server.
pub struct WsDoc {
  incoming : @schema.Schema?
  outgoing : @schema.Schema?
  subprotocols : Array[String]
}

///|
/// One definition for server, client, in-process transport and test doubles.
pub struct WsEndpoint[S, I, In, Out] {
  priv handshake : Endpoint[S, I, NoError, Unit, @client.Buffered]
  priv incoming : WsCodec[In]?
  priv outgoing : WsCodec[Out]?
  priv protocols : Array[String]
  priv origins : @handshake.OriginPolicy
}

///|
/// Starts a WebSocket definition. messages() is required before use.
pub fn ws_endpoint() -> WsEndpoint[Unit, Unit, Unit, Unit] {
  {
    handshake: endpoint,
    incoming: None,
    outgoing: None,
    protocols: [],
    origins: SameOrigin,
  }
}

///|
/// Declares the handshake GET path.
pub fn[S, I, In, Out] WsEndpoint::get(
  self : WsEndpoint[S, I, In, Out],
  path : String,
) -> WsEndpoint[S, I, In, Out] {
  { ..self, handshake: self.handshake.get(path), }
}

///|
/// Uses the HTTP endpoint's bidirectional handshake inputs.
pub fn[S, I2, In, Out] WsEndpoint::input(
  self : WsEndpoint[S, Unit, In, Out],
  input : Input[I2],
) -> WsEndpoint[S, I2, In, Out] {
  {
    handshake: self.handshake.input(input),
    incoming: self.incoming,
    outgoing: self.outgoing,
    protocols: self.protocols,
    origins: self.origins,
  }
}

///|
/// Security is decoded and authenticated before upgrading.
pub fn[S2, I, In, Out] WsEndpoint::security(
  self : WsEndpoint[Unit, I, In, Out],
  security : Input[S2],
) -> WsEndpoint[S2, I, In, Out] {
  {
    handshake: self.handshake.security(security),
    incoming: self.incoming,
    outgoing: self.outgoing,
    protocols: self.protocols,
    origins: self.origins,
  }
}

///|
/// Declares client-to-server and server-to-client message codecs.
pub fn[S, I, A, B, In, Out] WsEndpoint::messages(
  self : WsEndpoint[S, I, A, B],
  incoming~ : WsCodec[In],
  outgoing~ : WsCodec[Out],
) -> WsEndpoint[S, I, In, Out] {
  {
    handshake: self.handshake,
    incoming: Some(incoming),
    outgoing: Some(outgoing),
    protocols: self.protocols,
    origins: self.origins,
  }
}

///|
/// Supported protocols; the first supported client offer wins.
pub fn[S, I, In, Out] WsEndpoint::subprotocols(
  self : WsEndpoint[S, I, In, Out],
  protocols : Array[String],
) -> WsEndpoint[S, I, In, Out] {
  { ..self, protocols: protocols.copy(), }
}

///|
/// Overrides SameOrigin; requests without Origin remain allowed.
pub fn[S, I, In, Out] WsEndpoint::origins(
  self : WsEndpoint[S, I, In, Out],
  origins : @handshake.OriginPolicy,
) -> WsEndpoint[S, I, In, Out] {
  {
    ..self,
    origins: match origins {
      Allow(values) => Allow(values.copy())
      _ => origins
    },
  }
}

///|
/// Names the operation in documentation.
pub fn[S, I, In, Out] WsEndpoint::operation_id(
  self : WsEndpoint[S, I, In, Out],
  id : String,
) -> WsEndpoint[S, I, In, Out] {
  { ..self, handshake: self.handshake.operation_id(id), }
}

///|
/// Summarizes the operation.
pub fn[S, I, In, Out] WsEndpoint::summary(
  self : WsEndpoint[S, I, In, Out],
  summary : String,
) -> WsEndpoint[S, I, In, Out] {
  { ..self, handshake: self.handshake.summary(summary), }
}

///|
/// Adds a documentation tag.
pub fn[S, I, In, Out] WsEndpoint::tag(
  self : WsEndpoint[S, I, In, Out],
  tag : String,
) -> WsEndpoint[S, I, In, Out] {
  { ..self, handshake: self.handshake.tag(tag), }
}

///|
/// Returns handshake metadata and separate message schemas. Router.docs()
/// collects the same value; OpenAPI projects only the handshake.
pub fn[S, I, In, Out] WsEndpoint::doc(
  self : WsEndpoint[S, I, In, Out],
) -> EndpointDoc {
  {
    ..self.handshake.doc(),
    outputs: [VariantDoc::new(101, description="Switching Protocols")],
    websocket: Some({
      incoming: self.incoming.map(c => c.schema()),
      outgoing: self.outgoing.map(c => c.schema()),
      subprotocols: self.protocols.copy(),
    }),
  }
}

///|
/// Authenticated server interpretation. Authentication failures are ordinary
/// HTTP responses, so applications can supply their challenges and statuses.
pub fn[S, I, In, Out, P] WsEndpoint::serve(
  self : WsEndpoint[S, I, In, Out],
  authenticate : async (S) -> Result[P, @mttp_core.Response],
  handle : async (P, I, TypedSession[In, Out]) -> Unit,
) -> ServerEndpoint {
  self.handshake.pipeline(
    (_, _, credentials) => authenticate(credentials),
    (request, _, principal, input) => {
      let offer = @handshake.check_client_request(
        request,
        origins=self.origins,
        subprotocols=self.protocols,
      ) catch {
        @handshake.Refusal(status~, headers~, ..) =>
          return {
            ..problem(status, @mttp_core.reason_phrase(status), []),
            headers: headers.set("content-type", "application/problem+json"),
          }
      }
      guard self.incoming is Some(incoming) && self.outgoing is Some(outgoing) else {
        return @mttp_core.Response::new(500)
      }
      let protocol = offer.subprotocols
        .iter()
        .find_first(p => offer.supported_subprotocols.contains(p))
      let response = offer.accept(subprotocol?=protocol)
      {
        ..response,
        attributes: response.attributes.put(@ws.server_handler, session => {
          handle(
            principal,
            input,
            TypedSession::new(session, incoming~, outgoing~),
          ) catch {
            // A propagated codec issue has already completed Close. Unwrap
            // SessionFailure so host adapters recognize ordinary peer Close.
            MessageDecode(..) => ()
            SessionFailure(error) => raise error
            error => raise error
          }
        }),
      }
    },
    doc=self.doc(),
  )
}

///|
/// Server interpretation without credentials.
pub fn[I, In, Out] WsEndpoint::serve_public(
  self : WsEndpoint[Unit, I, In, Out],
  handle : async (I, TypedSession[In, Out]) -> Unit,
) -> ServerEndpoint {
  self.serve(_ => Ok(()), (_, input, session) => handle(input, session))
}

///|
/// A runtime's existing WebSocket connect path. Receives the encoded relative
/// request and offered protocols; it joins a base URL and validates the 101.
pub type WsConnector = async (@mttp_core.Request, Array[String]) -> &@ws.Session raise @ws.WsError

///|
/// Wraps an already connected client Session, useful for test doubles and
/// custom transports. Invalid definitions raise before acquiring ownership.
pub fn[S, I, In, Out] WsEndpoint::client_session(
  self : WsEndpoint[S, I, In, Out],
  session : &@ws.Session,
) -> TypedSession[Out, In] raise DefinitionError {
  let problems = check_definitions([self.doc()]).filter(p => p.fatal)
  if !problems.is_empty() {
    raise DefinitionError(problems)
  }
  TypedSession::new(
    session,
    incoming=self.outgoing.unwrap(),
    outgoing=self.incoming.unwrap(),
  )
}

///|
/// Construction/handshake failures are values; cancellation remains an effect.
#non_exhaustive
#derive(Debug)
pub(all) enum WsConnectFailure {
  InvalidDefinition(Array[DefinitionProblem])
  InvalidHandshakeInput(String)
  ConnectFailed(@ws.WsError)
}

///|
/// Formats construction or handshake failures.
pub extend WsConnectFailure with @debug.Debug::{to_repr}

///|
/// Connects through a runtime connector (gaato/mttp/ws.connector), reversing
/// message directions for the client. No HTTP redirect or retry is implied.
pub async fn[S, I, In, Out] WsEndpoint::connect(
  self : WsEndpoint[S, I, In, Out],
  connector : WsConnector,
  security : S,
  input : I,
) -> Result[TypedSession[Out, In], WsConnectFailure] {
  let problems = check_definitions([self.doc()]).filter(p => p.fatal)
  if !problems.is_empty() {
    return Err(InvalidDefinition(problems))
  }
  let request = self.handshake.encode_request(security, input) catch {
    @client.InvalidRequest(message~) =>
      return Err(InvalidHandshakeInput(message))
  }
  let session = connector(request, self.protocols.copy()) catch {
    error => return Err(ConnectFailed(error))
  }
  // The checker above guarantees both codecs before any network work.
  Ok(
    TypedSession::new(
      session,
      incoming=self.outgoing.unwrap(),
      outgoing=self.incoming.unwrap(),
    ),
  )
}
