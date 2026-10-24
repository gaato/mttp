///|
pub(all) enum Location {
  Path
  Query
  Header
  Auth
  Body(streamed~ : Bool)
} derive(Debug)

///|
pub(all) struct Atom {
  location : Location
  name : String
} derive(Debug)

///|
pub(all) enum BodyValue {
  NoBody
  Buffered(Bytes)
  Streamed(&@model.BodyStream)
}

///|
pub(all) suberror InputErrors {
  InputErrors(Array[String])
} derive(Debug)

///|
/// Head-stage decode result: either complete, or waiting for the body.
pub struct Staged[T] {
  priv finish : (BodyValue) -> T raise InputErrors
}

///|
pub struct Input[T] {
  priv atoms : Array[Atom]
  priv decode : (@model.Request, Map[String, String]) -> Staged[T] raise InputErrors
  priv encode : (T, Array[(String, String)]) -> Unit
}

///|
pub fn unit() -> Input[Unit] {
  { atoms: [], decode: (_, _) => { finish: _ => () }, encode: (_, _) => () }
}

///|
pub fn path_int(name : String) -> Input[Int] {
  {
    atoms: [{ location: Path, name }],
    decode: (_, params) => {
      let v = params.get(name).unwrap_or("0")
      let n = try { @string.parse_int(v) } catch { _ => raise InputErrors(["bad \{name}"]) }
      { finish: _ => n }
    },
    encode: (v, sink) => sink.push((name, v.to_string())),
  }
}

///|
pub fn bearer() -> Input[String] {
  {
    atoms: [{ location: Auth, name: "authorization" }],
    decode: (req, _) => {
      let v = req.headers.iter().find_first(h => h.0 == "authorization")
      match v {
        Some((_, t)) => { finish: _ => t }
        None => raise InputErrors(["missing bearer"])
      }
    },
    encode: (t, sink) => sink.push(("authorization", t)),
  }
}

///|
pub fn[A, B, T] Input::map2(
  a : Input[A],
  b : Input[B],
  to : (A, B) -> T,
  from : (T) -> (A, B),
) -> Input[T] {
  {
    atoms: [..a.atoms, ..b.atoms],
    decode: (req, p) => {
      let sa = (a.decode)(req, p)
      let sb = (b.decode)(req, p)
      { finish: bv => to((sa.finish)(bv), (sb.finish)(bv)) }
    },
    encode: (t, sink) => {
      let (x, y) = from(t)
      (a.encode)(x, sink)
      (b.encode)(y, sink)
    },
  }
}

///|
pub(all) suberror NoError derive(Debug)

///|
pub struct Errors[E] {
  priv classify : (Error) -> E?
}

///|
pub fn no_errors() -> Errors[NoError] {
  { classify: _ => None }
}

///|
pub fn[E] Errors::new(classify : (Error) -> E?) -> Errors[E] {
  { classify, }
}

///|
pub struct Output[O] {
  priv status : Int
  priv encode : (O) -> Bytes
}

///|
pub fn no_content() -> Output[Unit] {
  { status: 204, encode: _ => b"" }
}

///|
pub fn text_out() -> Output[String] {
  { status: 200, encode: s => @utf8.encode(s) }
}

///|
pub struct Endpoint[S, I, E, O] {
  priv meth : @model.Method?
  priv path : Array[String]
  priv security : Input[S]
  priv input : Input[I]
  priv errors : Errors[E]
  priv output : Output[O]
}

///|
pub let endpoint : Endpoint[Unit, Unit, NoError, Unit] = {
  meth: None,
  path: [],
  security: unit(),
  input: unit(),
  errors: no_errors(),
  output: no_content(),
}

///|
/// Appends: base endpoints carry a prefix.
pub fn[S, I, E, O] Endpoint::path(self : Endpoint[S, I, E, O], template : String) -> Endpoint[S, I, E, O] {
  { ..self, path: [..self.path, template] }
}

///|
pub fn[S, I, E, O] Endpoint::get(self : Endpoint[S, I, E, O], template : String) -> Endpoint[S, I, E, O] {
  { ..self, meth: Some(Get), path: [..self.path, template] }
}

///|
/// Set-once: only an endpoint whose security slot is still Unit accepts one.
pub fn[I, E, O, S2] Endpoint::security(self : Endpoint[Unit, I, E, O], s : Input[S2]) -> Endpoint[S2, I, E, O] {
  { meth: self.meth, path: self.path, security: s, input: self.input, errors: self.errors, output: self.output }
}

///|
pub fn[S, E, O, I2] Endpoint::input(self : Endpoint[S, Unit, E, O], i : Input[I2]) -> Endpoint[S, I2, E, O] {
  { meth: self.meth, path: self.path, security: self.security, input: i, errors: self.errors, output: self.output }
}

///|
pub fn[S, I, O, E2] Endpoint::errors(self : Endpoint[S, I, NoError, O], e : Errors[E2]) -> Endpoint[S, I, E2, O] {
  { meth: self.meth, path: self.path, security: self.security, input: self.input, errors: e, output: self.output }
}

///|
pub fn[S, I, E, O2] Endpoint::output(self : Endpoint[S, I, E, Unit], o : Output[O2]) -> Endpoint[S, I, E, O2] {
  { meth: self.meth, path: self.path, security: self.security, input: self.input, errors: self.errors, output: o }
}

///|
/// Users construct these in middleware (CORS preflight), so pub(all).
pub(all) enum Outcome {
  Respond(@model.Response)
  Upgrade(@model.ResponseHead, async (Bytes) -> Unit)
}

///|
pub struct ServerEndpoint {
  priv run : async (@model.Request, Map[String, String]) -> Outcome
}

///|
pub fn[S, I, E, O, P] Endpoint::serve(
  self : Endpoint[S, I, E, O],
  authenticate : async (S) -> P,
  handle : async (P, I) -> O,
) -> ServerEndpoint {
  {
    run: async fn(req, params) {
      // 1. heads (security first), 2. auth before body, 3. body, 4. logic
      let ss = (self.security.decode)(req, params) catch {
        InputErrors(m) => return Respond({ status: 401, headers: [], body: Bytes(@utf8.encode(m.join(","))) })
      }
      let si = (self.input.decode)(req, params) catch {
        InputErrors(m) => return Respond({ status: 400, headers: [], body: Bytes(@utf8.encode(m.join(","))) })
      }
      let principal = authenticate((ss.finish)(NoBody)) catch {
        e => match (self.errors.classify)(e) {
          Some(_) => return Respond({ status: 403, headers: [], body: Empty })
          None => raise e
        }
      }
      let input = (si.finish)(match req.body { Bytes(b) => Buffered(b); Stream(s, ..) => Streamed(s); Empty => NoBody })
      let out = handle(principal, input)
      Respond({ status: self.output.status, headers: [], body: Bytes((self.output.encode)(out)) })
    },
  }
}
