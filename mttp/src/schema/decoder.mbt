///|
/// Codec applications allowed per JSON value of the input when the caller
/// passes no `max_steps`. Honest decoding applies a codec to each value a
/// bounded number of times (once per layer, once per union case tried); the
/// budget turns the cost of untagged unions that retry a deep subtree, which
/// is otherwise exponential in the nesting depth, into a linear one.
let steps_per_value : Int32 = 256

///|
/// The smallest default budget, so a small input never fails for want of it.
let min_default_steps : Int32 = 4096

///|
/// The work state of one top-level decode: every codec application on a JSON
/// value is one step. Codecs are reusable values, so the state lives here and
/// not in them.
priv struct Decoder {
  max_steps : Int32
  mut steps : Int32
  mut exhausted : Bool
}

///|
fn Decoder::new(input : Json, max_steps : Int32?) -> Decoder {
  let max_steps = match max_steps {
    Some(n) => n.max(1)
    None => default_steps(input)
  }
  { max_steps, steps: 0, exhausted: false, }
}

///|
/// `steps_per_value` per JSON value of `input`, at least `min_default_steps`.
fn default_steps(input : Json) -> Int32 {
  let limit = 2147483647 / steps_per_value
  let pending = [input]
  let mut values = 0
  while pending.pop() is Some(value) {
    values += 1
    if values >= limit {
      return 2147483647
    }
    match value {
      Array(items) => pending.append(items)
      Object(fields) =>
        for _, field in fields {
          pending.push(field)
        }
      _ => ()
    }
  }
  (values * steps_per_value).max(min_default_steps)
}

///|
/// Applies `codec` to one value, charging one step.
fn[T] Decoder::apply(
  self : Decoder,
  codec : JsonCodec[T],
  j : Json,
  path : String,
) -> T raise DecodeFailure {
  if self.exhausted || self.steps >= self.max_steps {
    self.exhausted = true
    raise DecodeFailure(
      kind=TooLarge(limit=self.max_steps),
      message="decoding needs more than \{self.max_steps} steps",
    )
  }
  self.steps += 1
  (codec.from_)(j, path, self)
}

///|
/// Records a child's failure as issues, so a container reports every
/// problem. An exhausted budget is not recorded: it ends the whole decode.
fn Decoder::absorb(
  self : Decoder,
  error : DecodeFailure,
  issues : Array[Issue],
  path : String,
  code : String,
) -> Unit raise DecodeFailure {
  if self.exhausted {
    raise error
  }
  match error {
    DecodeFailure(kind=Invalid(found), ..) => issues.append(found)
    _ => issues.push({ path, code, message: error.message(), })
  }
}
