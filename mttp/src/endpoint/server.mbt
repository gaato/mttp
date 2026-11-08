///|
/// The stage at which an endpoint input was rejected.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum FailureStage {
  Security
  Head
  Body
}

///|
/// Compares rejection stages.
pub extend FailureStage with Eq::{equal, not_equal}

///|
/// Formats rejection stages.
pub extend FailureStage with @debug.Debug::{to_repr}

///|
/// The request and input issues supplied to a server's rejection policy.
pub(all) struct FailureContext {
  request : @http.Request
  endpoint : EndpointDoc
  failures : Array[InputFailure]
  stage : FailureStage
}

///|
/// Shared limits and error policy supplied by the router.
pub(all) struct DispatchContext {
  max_body_bytes : Int32
  max_issues : Int32
  decode_failure : (FailureContext) -> @http.Response
  unhandled : (@http.Request, Error) -> @http.Response
}

///|
/// Creates dispatch limits and callbacks with bounded problem responses.
/// Adapter body streams retain their own hard ceiling even when an endpoint
/// overrides the default here; the smaller limit fails first.
pub fn DispatchContext::new(
  max_body_bytes~ : Int32 = 1048576,
  max_issues~ : Int32 = 100,
  decode_failure~ : (FailureContext) -> @http.Response = default_failure,
  unhandled~ : (@http.Request, Error) -> @http.Response = (_, _) => {
    problem(500, "Internal Server Error", [])
  },
) -> DispatchContext {
  { max_body_bytes, max_issues, decode_failure, unhandled, }
}

///|
/// Creates an input failure context.
pub fn FailureContext::new(
  request : @http.Request,
  endpoint : EndpointDoc,
  failures : Array[InputFailure],
  stage : FailureStage,
) -> FailureContext {
  { request, endpoint, failures, stage, }
}

///|
/// Template of the endpoint which dispatched a response, for middleware labels.
pub let route_template : @http.AttributeKey[String] = @http.AttributeKey::new(
  "route_template",
)

///|
/// An erased endpoint with its documented definition and server interpreter.
pub struct ServerEndpoint {
  priv doc : EndpointDoc
  priv run : async (@http.Request, Map[String, String], DispatchContext) -> @http.Response noraise
}

///|
/// Returns this server endpoint's definition metadata.
pub fn ServerEndpoint::doc(self : ServerEndpoint) -> EndpointDoc {
  {
    ..self.doc,
    segments: self.doc.segments.copy(),
    security: self.doc.security.copy(),
    inputs: self.doc.inputs.copy(),
    outputs: self.doc.outputs.copy(),
    errors: self.doc.errors.copy(),
    info: { ..self.doc.info, tags: self.doc.info.tags.copy(), },
  }
}

///|
fn discard(body : @http.Body) -> Unit {
  if body is Stream(stream) {
    stream.close()
  }
}

///|
/// Dispatches a matched route. Input ownership ends with a buffered response,
/// or transfers to the response stream until it finishes or closes.
pub async fn ServerEndpoint::dispatch(
  self : ServerEndpoint,
  req : @http.Request,
  params : Map[String, String],
  ctx : DispatchContext,
) -> @http.Response noraise {
  let mut transferred = false
  defer (if !transferred { discard(req.body) })
  let response = (self.run)(req, params, ctx)
  let response = own_response(req.body, response) catch {
    error => {
      let fallback = (ctx.unhandled)(req, error)
      own_response(req.body, fallback) catch {
        _ => @http.Response::new(500)
      }
    }
  }
  transferred = response.body is Stream(_)
  let response = if response.status == 413 {
    { ..response, headers: response.headers.set("connection", "close"), }
  } else {
    response
  }
  {
    ..response,
    attributes: response.attributes.put(route_template, self.doc.template),
  }
}

///|
fn own_response(
  request : @http.Body,
  response : @http.Response,
) -> @http.Response raise @http.TransportError {
  errdefer response.close()
  if response.body is Stream(stream) {
    let owner : &@http.BodyStream = ResponseOwner::{
      reader: stream.take(),
      request,
      closed: false,
    }
    {
      ..response,
      body: Stream(@http.StreamBody::new(owner, length?=stream.length())),
    }
  } else {
    response
  }
}

///|
fn body_atom(atoms : Array[Atom]) -> Atom {
  for atom in atoms {
    if atom.location is (Body(..) | RawBody) {
      return atom
    }
  }
  Atom::new(Derived, "body", @schema.Schema::of({}))
}

///|
async fn read_body(
  body : @http.Body,
  limit : Int32,
) -> Bytes raise @schema.DecodeFailure {
  @client.read_body(body, limit) catch {
    @http.TransportError(kind=TooLarge(limit~), ..) =>
      raise @schema.DecodeFailure(
        kind=TooLarge(limit~),
        message="request body exceeds limit",
      )
    _ =>
      raise @schema.DecodeFailure(
        kind=Malformed,
        message="request body could not be read",
      )
  }
}

///|
fn[S, I, E, O, P, M] Endpoint::pipeline(
  self : Endpoint[S, I, E, O, M],
  authenticate : async (@http.Request, DispatchContext, S) -> Result[
    P,
    @http.Response,
  ],
  logic : async (@http.Request, DispatchContext, P, I) -> @http.Response,
) -> ServerEndpoint {
  let doc = self.doc()
  let streamed = self.input.atoms
    .iter()
    .any(a => a.location is Body(streamed=true, ..))
  let run = (
    req : @http.Request,
    captures : Map[String, String],
    ctx : DispatchContext,
  ) => {
    let limit = self.max_body_bytes.unwrap_or(ctx.max_body_bytes).max(0)
    let failure = (stage : FailureStage, failures : Array[InputFailure]) => {
      let failures = bounded_failures(failures, ctx.max_issues.max(1))
      (ctx.decode_failure)({ request: req, endpoint: doc, failures, stage, })
    }
    req.validate() catch {
      _ =>
        return failure(Head, [
          InputFailure::new(
            Atom::new(Derived, "request", @schema.Schema::of({})),
            @schema.DecodeFailure(kind=Malformed, message="invalid request"),
          ),
        ])
    }
    let query = {
      let url = @http.Url::parse(req.url) catch {
        _ =>
          return failure(Head, [
            InputFailure::new(
              Atom::new(Query, "", @schema.Schema::of({})),
              @schema.DecodeFailure(
                kind=Malformed,
                message="invalid request URL",
              ),
            ),
          ])
      }
      @http.form_urldecode(url.query.unwrap_or("")) catch {
        _ =>
          return failure(Head, [
            InputFailure::new(
              Atom::new(Query, "", @schema.Schema::of({})),
              @schema.DecodeFailure(
                kind=Malformed,
                message="too many query parameters",
              ),
            ),
          ])
      }
    }
    let head = Head::new(req, captures~, query~)
    let sec_failures = []
    let security = Some((self.security.decode)(head)) catch {
      InputErrors(fs) => {
        sec_failures.append(fs)
        None
      }
    }
    let input_failures = []
    let input = Some((self.input.decode)(head)) catch {
      InputErrors(fs) => {
        input_failures.append(fs)
        None
      }
    }
    guard security is Some(security) else {
      return failure(Security, sec_failures)
    }
    let mut body : BodyValue = NoBody
    let mut body_read = false
    if security.needs_body {
      let bytes = read_body(req.body, limit) catch {
        error =>
          return failure(Security, [
            InputFailure::new(body_atom(self.security.atoms), error),
          ])
      }
      body = Buffered(bytes)
      body_read = true
    }
    let security_value = (security.finish)(body) catch {
      InputErrors(fs) => return failure(Security, fs)
    }
    let principal = match authenticate(req, ctx, security_value) {
      Ok(principal) => principal
      Err(response) => return response
    }
    guard input is Some(input) else { return failure(Head, input_failures) }
    let stream_failure : Ref[@schema.DecodeFailure?] = Ref(None)
    if !body_read && input.needs_body {
      body = if streamed {
        let reader : &@http.BodyStream = match req.body {
          Stream(stream) =>
            stream.take() catch {
              _ =>
                return failure(Body, [
                  InputFailure::new(
                    body_atom(self.input.atoms),
                    @schema.DecodeFailure(
                      kind=Malformed,
                      message="request stream unavailable",
                    ),
                  ),
                ])
            }
          Bytes(bytes) => BufferedStream::new(bytes)
          Empty => BufferedStream::new(b"")
          @http.Body::.. =>
            return failure(Body, [
              InputFailure::new(
                body_atom(self.input.atoms),
                @schema.DecodeFailure(
                  kind=Malformed,
                  message="unsupported body kind",
                ),
              ),
            ])
        }
        Streamed(LimitedInput::{
          reader,
          limit,
          count: 0L,
          failure: stream_failure,
          closed: false,
        })
      } else {
        Buffered(
          read_body(req.body, limit) catch {
            error =>
              return failure(Body, [
                InputFailure::new(body_atom(self.input.atoms), error),
              ])
          },
        )
      }
    }
    let value = (input.finish)(body) catch {
      InputErrors(fs) => return failure(Body, fs)
    }
    // Input read failures take precedence even if user logic propagated the
    // read exception. Preserve unrelated exceptions for the server policy.
    let outcome = Ok(logic(req, ctx, principal, value)) catch {
      error => Err(error)
    }
    if stream_failure.val is Some(error) {
      if outcome is Ok(response) {
        response.close()
      }
      return failure(Body, [
        InputFailure::new(body_atom(self.input.atoms), error),
      ])
    }
    match outcome {
      Ok(response) => response
      Err(error) => raise error
    }
  }
  {
    doc,
    run: (req, captures, ctx) => {
      run(req, captures, ctx) catch {
        error => (ctx.unhandled)(req, error)
      }
    },
  }
}

///|
fn[E] respond_error(
  out : Out[E, @client.Buffered],
  req : @http.Request,
  error : E,
  ctx : DispatchContext,
) -> @http.Response {
  out
  .encode(error)
  .unwrap_or_else(() => {
    (ctx.unhandled)(req, Failure("no declared error variant matched"))
  })
}

///|
/// Interprets an endpoint with credentials first, then regular inputs and the
/// handler. Declared errors use their variants; other errors use server policy.
pub fn[S, I, E, O, P, M] Endpoint::serve(
  self : Endpoint[S, I, E, O, M],
  authenticate : async (S) -> Result[P, E],
  handle : async (P, I) -> Result[O, E],
) -> ServerEndpoint {
  self.pipeline(
    (req, ctx, security) => {
      match authenticate(security) {
        Ok(principal) => Ok(principal)
        Err(error) => Err(respond_error(self.errors, req, error, ctx))
      }
    },
    (req, ctx, principal, input) => {
      let value = match handle(principal, input) {
        Ok(value) => value
        Err(error) => return respond_error(self.errors, req, error, ctx)
      }
      self.output
      .encode(value)
      .unwrap_or_else(() => {
        (ctx.unhandled)(req, Failure("no output variant matched"))
      })
    },
  )
}

///|
/// Interprets an endpoint with no security input.
pub fn[I, E, O, M] Endpoint::serve_public(
  self : Endpoint[Unit, I, E, O, M],
  handle : async (I) -> Result[O, E],
) -> ServerEndpoint {
  self.serve(_ => Ok(()), (_, input) => handle(input))
}
