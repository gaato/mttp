///|
/// FailureContext/FailureStage/DispatchContext live here, not in `router`:
/// dispatch detects failures and router imports endpoint (I-01).
pub(all) enum FailureStage {
  Security
  Head
  Body
} derive(Eq, Debug)

///|
pub(all) struct FailureContext {
  request : @model.Request
  endpoint : EndpointDoc
  failures : Array[InputFailure]
  stage : FailureStage
}

///|
/// Built once by Router::new from ServerOptions (closures, because
/// ServerOptions lives in `router`).
pub(all) struct DispatchContext {
  max_body_bytes : Int
  max_issues : Int
  decode_failure : (FailureContext) -> @model.Response
  unhandled : (@model.Request, Error) -> @model.Response
}

///|
/// Set on the response by dispatch, so request-level middleware can label
/// metrics and spans by route after `next` (SC-06).
pub let route_template : @model.AttributeKey[String] = @model.AttributeKey::new("route_template")

///|
pub struct ServerEndpoint {
  priv doc : EndpointDoc
  priv run : async (@model.Request, Map[String, String], DispatchContext) -> @model.Response noraise
}

///|
pub fn ServerEndpoint::doc(self : ServerEndpoint) -> EndpointDoc {
  self.doc
}

///|
pub async fn ServerEndpoint::dispatch(
  self : ServerEndpoint,
  req : @model.Request,
  params : Map[String, String],
  ctx : DispatchContext,
) -> @model.Response noraise {
  (self.run)(req, params, ctx)
}

///|
fn discard(body : @model.Body) -> Unit {
  if body is Stream(s, ..) {
    s.close()
  }
}

///|
async fn read_body(body : @model.Body, limit : Int) -> Bytes raise @schema.DecodeFailure {
  match body {
    Bytes(b) => if b.length() > limit { raise TooLarge(limit~) } else { b }
    Stream(s, length~) => {
      if length is Some(n) && n > limit.to_int64() {
        s.close()
        raise TooLarge(limit~)
      }
      @model.read_bounded(s, limit) catch {
        @model.TransportError(kind=TooLarge(..), ..) => raise TooLarge(limit~)
        // a reset or timeout while reading is not an oversized body
        e => raise Malformed("request body could not be read: \{e.message()}")
      }
    }
    _ => b""
  }
}

///|
fn truncate(fs : Array[InputFailure], max : Int) -> Array[InputFailure] {
  if fs.length() <= max { fs } else { fs[:max].to_array() }
}

///|
/// The staged pipeline behind serve. `logic` returns the
/// response for an authenticated, decoded request.
fn[S, I, E, O, P] Endpoint::pipeline(
  self : Endpoint[S, I, E, O],
  authenticate : async (@model.Request, DispatchContext, S) -> Result[P, @model.Response],
  logic : async (@model.Request, DispatchContext, P, I) -> @model.Response,
) -> ServerEndpoint {
  let doc = self.doc()
  let streamed = self.input.atoms.iter().any(a => a.location is Body(streamed=true, ..))
  let run = async fn(
    req : @model.Request,
    captures : Map[String, String],
    ctx : DispatchContext,
  ) -> @model.Response {
    let limit = self.max_body_bytes.unwrap_or(ctx.max_body_bytes)
    let failure = (stage, fs) => (ctx.decode_failure)({
      request: req,
      endpoint: doc,
      failures: truncate(fs, ctx.max_issues),
      stage,
    })
    let query = @model.Url::parse(req.url).query_params() catch { _ => [] }
    let head = { request: req, captures, query }
    let sec_failures = []
    let sec = Some((self.security.decode)(head)) catch {
      InputErrors(fs) => {
        sec_failures.append(fs)
        None
      }
    }
    let in_failures = []
    let inp = Some((self.input.decode)(head)) catch {
      InputErrors(fs) => {
        in_failures.append(fs)
        None
      }
    }
    // 3. credentials first; body closed unread
    guard sec is Some(sec) else {
      discard(req.body)
      return failure(Security, sec_failures)
    }
    // 4. raw_body in the security input: buffer now, bounded
    let mut body_value : BodyValue = NoBody
    let mut body_read = false
    if sec.needs_body {
      let bytes = read_body(req.body, limit) catch {
        f => {
          let a = self.security.atoms.filter(a => a.location is RawBody)
          return failure(Security, [{ atom: a[0], failure: f }])
        }
      }
      body_value = Buffered(bytes)
      body_read = true
    }
    let s = (sec.finish)(body_value) catch {
      InputErrors(fs) => return failure(Security, fs)
    }
    // 5. authenticate
    let authenticated = try { authenticate(req, ctx, s) } catch {
      e => {
        if !body_read {
          discard(req.body)
        }
        return (ctx.unhandled)(req, e)
      }
    }
    let principal = match authenticated {
      Ok(p) => p
      Err(resp) => {
        if !body_read {
          discard(req.body)
        }
        return resp
      }
    }
    // 6. regular head failures, every problem listed
    guard inp is Some(inp) else {
      if !body_read {
        discard(req.body)
      }
      return failure(Head, in_failures)
    }
    // 7. body
    if !body_read {
      body_value = if !inp.needs_body {
        discard(req.body)
        NoBody
      } else if streamed {
        match req.body {
          Stream(st, ..) => Streamed(st)
          Bytes(b) => Buffered(b)
          _ => NoBody
        }
      } else {
        let bytes = read_body(req.body, limit) catch {
          f => {
            let a = self.input.atoms.filter(a => a.location is Body(..))
            return failure(Body, [{ atom: a[0], failure: f }])
          }
        }
        Buffered(bytes)
      }
    }
    let i = (inp.finish)(body_value) catch {
      InputErrors(fs) => return failure(Body, fs)
    }
    // 8. logic
    logic(req, ctx, principal, i) catch {
      e => (ctx.unhandled)(req, e)
    }
  }
  {
    doc,
    run: async fn(req, captures, ctx) noraise {
      let resp = run(req, captures, ctx) catch { e => (ctx.unhandled)(req, e) }
      let resp = if resp.status == 413 && !resp.closes_connection() {
        { ..resp, headers: resp.headers.set("connection", "close") }
      } else {
        resp
      }
      { ..resp, attributes: resp.attributes.put(route_template, doc.template) }
    },
  }
}

///|
fn[E] Errors::respond(self : Errors[E], req : @model.Request, e : Error, ctx : DispatchContext) -> @model.Response {
  match (self.classify)(e) {
    Some(declared) =>
      match self.out.encode(declared) {
        Some(r) => r
        None => (ctx.unhandled)(req, e)
      }
    None => (ctx.unhandled)(req, e)
  }
}

///|
pub fn[S, I, E, O, P] Endpoint::serve(
  self : Endpoint[S, I, E, O],
  authenticate : async (S) -> P,
  handle : async (P, I) -> O,
) -> ServerEndpoint {
  self.pipeline(
    async fn(req, ctx, s) {
      Ok(authenticate(s)) catch { e => Err(self.errors.respond(req, e, ctx)) }
    },
    async fn(req, ctx, p, i) {
      let o = handle(p, i) catch { e => return self.errors.respond(req, e, ctx) }
      match self.output.encode(o) {
        Some(r) => r
        None => (ctx.unhandled)(req, Failure("no output variant matched"))
      }
    },
  )
}

///|
pub fn[I, E, O] Endpoint::serve_public(
  self : Endpoint[Unit, I, E, O],
  handle : async (I) -> O,
) -> ServerEndpoint {
  self.serve(async fn(_) { () }, async fn(_, i) { handle(i) })
}

