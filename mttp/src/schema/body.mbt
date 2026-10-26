///|
/// Bytes <-> T with a media type: what a body input or output carries.
pub struct BodyCodec[T] {
  priv media_type_ : String
  priv decode_ : (Bytes) -> T raise DecodeFailure
  priv encode_ : (T) -> Bytes
  priv schema_ : Schema
}

///|
/// Creates a body codec for a media type. Decode receives caller-bounded bytes;
/// encode must be defined for every value supplied by the application.
pub fn[T] BodyCodec::new(
  media_type : String,
  decode : (Bytes) -> T raise DecodeFailure,
  encode : (T) -> Bytes,
  schema : Schema,
) -> BodyCodec[T] {
  {
    media_type_: media_type,
    decode_: decode,
    encode_: encode,
    schema_: schema,
  }
}

///|
/// Returns the media type emitted and accepted by this body codec.
pub fn[T] BodyCodec::media_type(self : BodyCodec[T]) -> String {
  self.media_type_
}

///|
/// Decodes an already buffered body. The caller imposes its byte limit.
pub fn[T] BodyCodec::decode(
  self : BodyCodec[T],
  b : Bytes,
) -> T raise DecodeFailure {
  (self.decode_)(b)
}

///|
/// Serializes a typed value to body bytes.
pub fn[T] BodyCodec::encode(self : BodyCodec[T], v : T) -> Bytes {
  (self.encode_)(v)
}

///|
/// Returns the schema for this media type's decoded representation.
pub fn[T] BodyCodec::schema(self : BodyCodec[T]) -> Schema {
  self.schema_
}

///|
/// A UTF-8 JSON body codec: refuses duplicate keys and nesting beyond 128, and preserves exact number lexemes.
pub fn[T] JsonCodec::body(self : JsonCodec[T]) -> BodyCodec[T] {
  {
    media_type_: "application/json",
    decode_: b => {
      let text = @utf8.decode(b) catch { _ => raise malformed("not UTF-8") }
      let j = @json.parse(
        text,
        max_nesting_depth=128,
        reject_duplicate_keys=true,
        preserve_number_repr=true,
      ) catch {
        e => raise malformed(e.to_string())
      }
      (self.from_)(j, "")
    },
    encode_: v => @text.encode_utf8((self.to_)(v).stringify()),
    schema_: self.schema_,
  }
}

///|
/// Opaque byte bodies, without copying or interpreting their contents.
pub let raw_bytes : BodyCodec[Bytes] = {
  media_type_: "application/octet-stream",
  decode_: b => b,
  encode_: b => b,
  schema_: Schema::of({
    "type": "string",
    "contentMediaType": "application/octet-stream",
  }),
}

///|
/// UTF-8 text bodies. Decoding is strict; encoding replaces lone surrogates.
pub let text_body : BodyCodec[String] = {
  media_type_: "text/plain",
  decode_: b => @utf8.decode(b) catch { _ => raise malformed("not UTF-8") },
  encode_: s => @text.encode_utf8(s),
  schema_: Schema::of({ "type": "string" }),
}

///|
/// Ordered application/x-www-form-urlencoded pairs with duplicate names.
/// Invalid escapes remain literal and invalid UTF-8 is replaced, following
/// the form parser. At most max_pairs (default 256) pairs are decoded.
pub fn form_body(
  max_pairs~ : Int32 = 256,
) -> BodyCodec[Array[(String, String)]] {
  {
    media_type_: "application/x-www-form-urlencoded",
    decode_: bytes => {
      @form.decode(@utf8.decode_lossy(bytes, ignore_bom=true), max_pairs) catch {
        @form.InvalidLimit => raise malformed("negative form pair limit")
        @form.TooMany(limit) =>
          raise DecodeFailure(
            kind=TooLarge(limit~),
            message="too many form pairs",
          )
      }
    },
    encode_: pairs => @text.encode_utf8(@form.encode(pairs)),
    schema_: Schema::of({
      "type": "object",
      "additionalProperties": { "type": "string" },
    }),
  }
}
