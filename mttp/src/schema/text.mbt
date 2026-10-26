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
    @string.parse_int(s) catch {
      _ => raise malformed("not an integer: \{s}")
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
