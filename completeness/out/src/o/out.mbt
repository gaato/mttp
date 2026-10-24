// What the server writes / the client reads for one output value.
pub(all) struct Wire { status : Int; headers : Array[(String, String)]; media : String?; body : Bytes } derive(Debug, Eq)

pub(all) suberror OutError { NotAcceptable(String); Mismatch(String) } derive(Debug)

// An output: atoms for docs + staged closures, like Input.
pub(all) struct OutDoc { status : Int?; headers : Array[String]; media : Array[String] } derive(Debug)

pub struct Out[T] {
  doc : OutDoc
  // accept: the request's Accept header (None = anything); raise NotAcceptable -> 406
  encode : (T, String?, Wire) -> Wire raise OutError
  decode : (Wire) -> T raise OutError
}

pub fn json_out(status~ : Int = 200) -> Out[Json] {
  {
    doc: { status: Some(status), headers: [], media: ["application/json"] },
    encode: (v, _, w) => { ..w, status, media: Some("application/json"), body: @utf8.encode(v.stringify()) },
    decode: w => @json.parse(@utf8.decode(w.body)) catch { _ => raise Mismatch("json") },
  }
}

// tapir header[T](name) as an output: type-changing pair, like Input::map2.
pub fn[T] Out::and_header(self : Out[T], name : String) -> Out[(T, String)] {
  {
    doc: { ..self.doc, headers: [..self.doc.headers, name] },
    encode: (v, acc, w) => {
      let w2 = (self.encode)(v.0, acc, w)
      { ..w2, headers: [..w2.headers, (name, v.1)] }
    },
    decode: w => {
      let t = (self.decode)(w)
      match w.headers.iter().find_first(h => h.0.to_lower() == name.to_lower()) {
        Some((_, h)) => (t, h)
        None => raise Mismatch("missing header \{name}")
      }
    },
  }
}

// tapir statusCode: a dynamic status as part of the value.
pub fn[T] Out::and_status(self : Out[T]) -> Out[(T, Int)] {
  {
    doc: { ..self.doc, status: None },
    encode: (v, acc, w) => { ..(self.encode)(v.0, acc, w), status: v.1 },
    decode: w => ((self.decode)(w), w.status),
  }
}

// tapir oneOfBody: same value, several media types, chosen by Accept; 406 when none fits.
pub fn[T] one_of_body(status : Int, bodies : Array[(String, (T) -> Bytes, (Bytes) -> T raise OutError)]) -> Out[T] {
  {
    doc: { status: Some(status), headers: [], media: bodies.map(b => b.0) },
    encode: (v, accept, w) => {
      for b in bodies {
        let ok = match accept { None => true; Some(a) => a.contains(b.0) || a.contains("*/*") }
        if ok { return { ..w, status, media: Some(b.0), body: (b.1)(v) } }
      }
      raise NotAcceptable(accept.unwrap_or(""))
    },
    decode: w => {
      for b in bodies { if w.media == Some(b.0) { return (b.2)(w.body) } }
      raise Mismatch("unsupported media \{w.media}")
    },
  }
}

pub fn[T] Out::write(self : Out[T], v : T, accept? : String) -> Wire raise OutError {
  (self.encode)(v, accept, { status: 0, headers: [], media: None, body: b"" })
}
