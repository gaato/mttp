///|
/// String <-> T for path, query, header and cookie values.
pub struct TextCodec[T] {
  priv decode_ : (String) -> T raise DecodeFailure
  priv encode_ : (T) -> String
  priv schema_ : Schema
}

///|
/// Creates a reversible text codec with its corresponding schema.
pub fn[T] TextCodec::new(
  decode : (String) -> T raise DecodeFailure,
  encode : (T) -> String,
  schema : Schema,
) -> TextCodec[T] {
  { decode_: decode, encode_: encode, schema_: schema, }
}

///|
/// Decodes one text value or reports a structured input error.
pub fn[T] TextCodec::decode(
  self : TextCodec[T],
  s : String,
) -> T raise DecodeFailure {
  (self.decode_)(s)
}

///|
/// Encodes one value using the codec's inverse mapping.
pub fn[T] TextCodec::encode(self : TextCodec[T], v : T) -> String {
  (self.encode_)(v)
}

///|
/// Returns the schema describing decoded values and constraints.
pub fn[T] TextCodec::schema(self : TextCodec[T]) -> Schema {
  self.schema_
}

///|
/// Checked signed 32-bit decimal text.
pub let int : TextCodec[Int32] = TextCodec::new(
  s => {
    guard is_decimal_integer(s) else { raise malformed("expected int32") }
    @string.parse_int(s) catch {
      _ => raise malformed("expected int32")
    }
  },
  i => i.to_string(),
  Schema::of({ "type": "integer", "format": "int32" }),
)

///|
/// Unmodified text without validation constraints.
pub let string : TextCodec[String] = TextCodec::new(
  s => s,
  s => s,
  Schema::of({ "type": "string" }),
)

///|
/// A check plus the JSON Schema keywords that state it.
pub struct Validator[T] {
  priv check : (T) -> String?
  priv keywords : Map[String, Json]
}

///|
/// An inclusive lower integer bound.
pub fn minimum(n : Int32) -> Validator[Int32] {
  {
    check: v => if v < n { Some("must be >= \{n}") } else { None },
    keywords: { "minimum": Json(n) },
  }
}

///|
/// An upper string length bound measured in Unicode code points.
pub fn max_length(n : Int32) -> Validator[String] {
  {
    // JSON Schema counts code points; length() would count UTF-16 units
    check: v => {
      if v.iter().count() > n {
        Some("longer than \{n}")
      } else {
        None
      }
    },
    keywords: if n < 0 {
      { "not": {} }
    } else {
      { "maxLength": Json(n) }
    },
  }
}

///|
/// Adds a decoding constraint and its JSON Schema keywords.
pub fn[T] TextCodec::validate(
  self : TextCodec[T],
  v : Validator[T],
) -> TextCodec[T] {
  {
    decode_: s => {
      let x = (self.decode_)(s)
      match (v.check)(x) {
        Some(msg) =>
          raise invalid([{ path: "", code: "constraint", message: msg, }])
        None => x
      }
    },
    encode_: self.encode_,
    schema_: self.schema_.patch(v.keywords),
  }
}

///|
/// Maps the decoded type and its inverse while retaining the schema.
pub fn[T, U] TextCodec::map(
  self : TextCodec[T],
  to : (T) -> U raise DecodeFailure,
  from : (U) -> T,
) -> TextCodec[U] {
  {
    decode_: s => to((self.decode_)(s)),
    encode_: u => (self.encode_)(from(u)),
    schema_: self.schema_,
  }
}

///|
/// `[+-]?[0-9]+`: decimal digits only, so `0x10`, `0b1` and `1_000`, which
/// `@string.parse_int` also reads, are refused as the schema's integer says.
fn is_decimal_integer(s : String) -> Bool {
  let chars = s.to_array()
  let start = if chars.get(0) is Some('+' | '-') { 1 } else { 0 }
  let end = skip_digits(chars, start)
  end > start && end == chars.length()
}

///|
/// A decimal number: `[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?`.
/// Refuses the underscores, `inf` and `NaN` that `@string.parse_double`
/// would read.
fn is_decimal_number(s : String) -> Bool {
  let chars = s.to_array()
  let sign = if chars.get(0) is Some('+' | '-') { 1 } else { 0 }
  let int_end = skip_digits(chars, sign)
  let (frac_start, frac_end) = if chars.get(int_end) is Some('.') {
    (int_end + 1, skip_digits(chars, int_end + 1))
  } else {
    (int_end, int_end)
  }
  if int_end == sign && frac_end == frac_start {
    return false
  }
  guard chars.get(frac_end) is Some('e' | 'E') else {
    return frac_end == chars.length()
  }
  let exp_start = if chars.get(frac_end + 1) is Some('+' | '-') {
    frac_end + 2
  } else {
    frac_end + 1
  }
  let exp_end = skip_digits(chars, exp_start)
  exp_end > exp_start && exp_end == chars.length()
}

///|
/// The index of the first non-digit at or after `at`.
fn skip_digits(chars : Array[Char], at : Int32) -> Int32 {
  let mut i = at
  while chars.get(i) is Some('0'..<='9') {
    i += 1
  }
  i
}
