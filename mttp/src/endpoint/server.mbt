///|
/// The stage at which an endpoint input was rejected.
#non_exhaustive
pub(all) enum FailureStage {
  Security
  Head
  Body
} derive(Eq, Debug)

///|
/// Compares rejection stages.
pub extend FailureStage with Eq::{equal, not_equal}

///|
/// Formats rejection stages.
pub extend FailureStage with @debug.Debug::{to_repr}

///|
/// The request and input issues supplied to a server's rejection policy.
pub(all) struct FailureContext {
  request : @model.Request
  endpoint : EndpointDoc
  failures : Array[InputFailure]
  stage : FailureStage
}

///|
/// Shared limits and error policy supplied by the router.
pub(all) struct DispatchContext {
  max_body_bytes : Int32
  max_issues : Int32
  decode_failure : (FailureContext) -> @model.Response
  unhandled : (@model.Request, Error) -> @model.Response
}

///|
/// Creates dispatch limits and callbacks. Defaults return plain 400/500;
/// Router installs its problem+json and authentication-aware policies.
pub fn DispatchContext::new(
  max_body_bytes~ : Int32 = 1048576,
  max_issues~ : Int32 = 100,
  decode_failure~ : (FailureContext) -> @model.Response = _ => {
    @model.Response::new(400)
  },
  unhandled~ : (@model.Request, Error) -> @model.Response = (_, _) => {
    @model.Response::new(500)
  },
) -> DispatchContext {
  { max_body_bytes, max_issues, decode_failure, unhandled, }
}

///|
/// Creates an input failure context.
pub fn FailureContext::new(
  request : @model.Request,
  endpoint : EndpointDoc,
  failures : Array[InputFailure],
  stage : FailureStage,
) -> FailureContext {
  { request, endpoint, failures, stage, }
}

///|
/// Template of the endpoint which dispatched a response, for middleware labels.
pub let route_template : @model.AttributeKey[String] = @model.AttributeKey::new(
  "route_template",
)

///|
/// An erased endpoint with its documented definition and server interpreter.
pub struct ServerEndpoint {
  priv doc : EndpointDoc
  priv run : async (@model.Request, Map[String, String], DispatchContext) -> @model.Response noraise
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
fn discard(body : @model.Body) -> Unit {
  if body is Stream(stream) {
    stream.close()
  }
}

///|
/// Dispatches a matched route. Input ownership ends with a buffered response,
/// or transfers to the response stream until it finishes or closes.
pub async fn ServerEndpoint::dispatch(
  self : ServerEndpoint,
  req : @model.Request,
  params : Map[String, String],
  ctx : DispatchContext,
) -> @model.Response noraise {
  let mut transferred = false
  defer (if !transferred { discard(req.body) })
  let response = (self.run)(req, params, ctx)
  let response = own_response(req.body, response) catch {
    error => {
      let fallback = (ctx.unhandled)(req, error)
      own_response(req.body, fallback) catch {
        _ => @model.Response::new(500)
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
  request : @model.Body,
  response : @model.Response,
) -> @model.Response raise @model.TransportError {
  errdefer response.close()
  if response.body is Stream(stream) {
    let owner : &@model.BodyStream = ResponseOwner::{
      reader: stream.take(),
      request,
      closed: false,
    }
    {
      ..response,
      body: Stream(@model.StreamBody::new(owner, length?=stream.length())),
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
  body : @model.Body,
  limit : Int32,
) -> Bytes raise @schema.DecodeFailure {
  @client.read_body(body, limit) catch {
    @model.TransportError(kind=TooLarge(..), ..) =>
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
fn[S, I, E, O, P] Endpoint::pipeline(
  self : Endpoint[S, I, E, O],
  authenticate : async (@model.Request, DispatchContext, S) -> Result[
    P,
    @model.Response,
  ],
  logic : async (@model.Request, DispatchContext, P, I) -> @model.Response,
) -> ServerEndpoint {
  let doc = self.doc()
  let streamed = self.input.atoms
    .iter()
    .any(a => a.location is Body(streamed=true, ..))
  let run = (
    req : @model.Request,
    captures : Map[String, String],
    ctx : DispatchContext,
  ) => {
    let limit = self.max_body_bytes.unwrap_or(ctx.max_body_bytes).max(0)
    let failure = (stage : FailureStage, failures : Array[InputFailure]) => {
      let max = ctx.max_issues.max(1)
      let failures = if failures.length() > max {
        failures[:max].to_owned()
      } else {
        failures
      }
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
      let url = @model.Url::parse(req.url) catch {
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
      @model.form_urldecode(url.query.unwrap_or("")) catch {
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
        let reader : &@model.BodyStream = match req.body {
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
          @model.Body::.. =>
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
    let response = logic(req, ctx, principal, value)
    if stream_failure.val is Some(error) {
      response.close()
      return failure(Body, [
        InputFailure::new(body_atom(self.input.atoms), error),
      ])
    }
    response
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
fn[E] Errors::respond(
  self : Errors[E],
  req : @model.Request,
  error : Error,
  ctx : DispatchContext,
) -> @model.Response {
  match (self.classify)(error) {
    Some(declared) =>
      self.out
      .encode(declared)
      .unwrap_or_else(() => (ctx.unhandled)(req, error))
    None => (ctx.unhandled)(req, error)
  }
}

///|
/// Interprets an endpoint with credentials first, then regular inputs and the
/// handler. Declared errors use their variants; other errors use server policy.
pub fn[S, I, E, O, P] Endpoint::serve(
  self : Endpoint[S, I, E, O],
  authenticate : async (S) -> P,
  handle : async (P, I) -> O,
) -> ServerEndpoint {
  self.pipeline(
    (req, ctx, security) => {
      Ok(authenticate(security)) catch {
        error => Err(self.errors.respond(req, error, ctx))
      }
    },
    (req, ctx, principal, input) => {
      let value = handle(principal, input) catch {
        error => return self.errors.respond(req, error, ctx)
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
pub fn[I, E, O] Endpoint::serve_public(
  self : Endpoint[Unit, I, E, O],
  handle : async (I) -> O,
) -> ServerEndpoint {
  self.serve(_ => (), (_, input) => handle(input))
}
