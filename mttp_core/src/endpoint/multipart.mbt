///|
/// A bidirectional multipart form codec with an object schema. Use field,
/// file and pair to declare named parts, or new for application-specific forms.
pub struct MultipartCodec[T] {
  priv schema_ : @schema.Schema
  priv decode_ : (Array[@multipart.Part]) -> T raise @schema.DecodeFailure
  priv encode_ : (T) -> Array[@multipart.Part]
}

///|
/// Creates a codec for an application-defined form and its object schema.
/// The encoder must produce valid metadata for every supplied value.
pub fn[T] MultipartCodec::new(
  schema : @schema.Schema,
  decode : (Array[@multipart.Part]) -> T raise @schema.DecodeFailure,
  encode : (T) -> Array[@multipart.Part],
) -> MultipartCodec[T] {
  { schema_: schema, decode_: decode, encode_: encode, }
}

///|
/// One required named field. Duplicate occurrences are rejected and the
/// declared body codec validates its bytes. An omitted Content-Type defaults
/// to text/plain, as RFC 7578 specifies.
pub fn[T] multipart_field(
  name : String,
  codec : @schema.BodyCodec[T],
) -> MultipartCodec[T] {
  let defs = Map([])
  let problems = []
  let property = @schema.Schema::of(codec.schema().reference(defs, problems~)).patch({
        "contentMediaType": Json(codec.media_type()),
      },
    ).json
  let schema = @schema.Schema::of({
    "type": "object",
    "properties": Json(Map([(name, property)])),
    "required": [name],
  })
  MultipartCodec::new(
    { ..schema, defs, problems, },
    parts => {
      let part = multipart_single(parts, name)
      let actual = part.content_type.unwrap_or("text/plain")
      if media_type_token(actual) != media_type_token(codec.media_type()) {
        raise unsupported_media_type(actual)
      }
      codec.decode(part.body.as_bytes().unwrap_or(b"")) catch {
        @schema.DecodeFailure(kind=Invalid(issues), message~) => {
          let prefix = "/" +
            name.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
          raise @schema.DecodeFailure(
            kind=Invalid(
              issues.map(issue => { ..issue, path: prefix + issue.path, }),
            ),
            message~,
          )
        }
        error => raise error
      }
    },
    value => {
      [
        {
          name,
          filename: None,
          content_type: Some(codec.media_type()),
          body: Bytes(codec.encode(value)),
        },
      ]
    },
  )
}

///|
fn multipart_single(
  parts : Array[@multipart.Part],
  name : String,
) -> @multipart.Part raise @schema.DecodeFailure {
  match parts.filter(p => p.name == name) {
    [part] => part
    [] => raise missing()
    values => raise multiple(values.length())
  }
}

///|
/// One required file, exposed as a BodyStream. The Router buffers the bounded
/// request before synchronous validation. For live parsing, construct a
/// MultipartReader over stream_body's source in the handler.
pub fn multipart_file(
  name : String,
  content_type~ : String = "application/octet-stream",
) -> MultipartCodec[@multipart.ReadPart] {
  MultipartCodec::new(
    @schema.Schema::of({
      "type": "object",
      "properties": Json(
        Map([
          (
            name,
            {
              "type": "string",
              "format": "binary",
              "contentMediaType": content_type,
            },
          ),
        ]),
      ),
      "required": [name],
    }),
    parts => {
      let part = multipart_single(parts, name)
      guard part.filename is Some(_) else {
        raise @schema.DecodeFailure(
          kind=Malformed,
          message="expected file part",
        )
      }
      let actual = part.content_type.unwrap_or("text/plain")
      if media_type_token(actual) != media_type_token(content_type) {
        raise unsupported_media_type(actual)
      }
      {
        head: {
          name,
          filename: part.filename,
          content_type: part.content_type,
          headers: @mttp_core.Headers::empty(),
        },
        body: BufferedStream::new(part.body.as_bytes().unwrap_or(b"")),
      }
    },
    part => {
      [
        {
          name,
          filename: part.head.filename,
          content_type: Some(content_type),
          body: Stream(@mttp_core.StreamBody::new(part.body)),
        },
      ]
    },
  )
}

///|
/// Combines fields, collecting failures from both codecs as named issues.
pub fn[A, B] MultipartCodec::pair(
  a : MultipartCodec[A],
  b : MultipartCodec[B],
) -> MultipartCodec[(A, B)] {
  let aj = a.schema_.json
  let bj = b.schema_.json
  let properties : Map[String, Json] = Map([])
  let required : Array[Json] = []
  let defs = Map([])
  let problems = []
  ignore(a.schema_.reference(defs, problems~))
  ignore(b.schema_.reference(defs, problems~))
  for schema in [aj, bj] {
    if schema is { "properties": Object(fields), .. } {
      for key, value in fields {
        if properties.contains(key) {
          problems.push("duplicate multipart field " + key)
        } else {
          properties[key] = value
        }
      }
    }
    if schema is { "required": Array(names), .. } {
      required.append(names)
    }
  }
  let schema = @schema.Schema::of({
    "type": "object",
    "properties": Json(properties),
    "required": Json(required),
  })
  MultipartCodec::new(
    { ..schema, defs, problems, },
    parts => {
      let issues : Array[@schema.Issue] = []
      let x = Some((a.decode_)(parts)) catch {
        error => {
          multipart_issues(issues, aj, error)
          None
        }
      }
      let y = Some((b.decode_)(parts)) catch {
        error => {
          multipart_issues(issues, bj, error)
          None
        }
      }
      guard x is Some(x) && y is Some(y) else {
        raise @schema.DecodeFailure(
          kind=Invalid(issues),
          message="invalid multipart fields",
        )
      }
      (x, y)
    },
    pair => [..(a.encode_)(pair.0), ..(b.encode_)(pair.1)],
  )
}

///|
fn multipart_first_name(schema : Json) -> String {
  if schema is { "properties": Object(fields), .. } &&
    fields.keys().next() is Some(name) {
    name.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
  } else {
    "body"
  }
}

///|
fn multipart_issues(
  issues : Array[@schema.Issue],
  schema : Json,
  error : @schema.DecodeFailure,
) -> Unit {
  match error {
    @schema.DecodeFailure(kind=Invalid(nested), ..) =>
      for issue in nested {
        issues.push(
          if issue.path.is_empty() {
            { ..issue, path: "/" + multipart_first_name(schema), }
          } else {
            issue
          },
        )
      }
    _ =>
      issues.push({
        path: "/" + multipart_first_name(schema),
        code: "multipart",
        message: error.message(),
      })
  }
}

///|
/// A typed multipart/form-data input. Unrecognized names are ignored, duplicate
/// declared names fail. Framing failures become 400; all bound overflows 413.
/// Client encoding draws a fresh boundary and transfers file streams once.
pub fn[T] multipart_body(
  codec : MultipartCodec[T],
  max_parts~ : Int32 = 256,
  max_header_bytes~ : Int32 = 16384,
  max_part_bytes~ : Int32 = 16777216,
) -> Input[T] {
  let a = atom(
    Body(media_type="multipart/form-data", streamed=false),
    "body",
    codec.schema_,
  )
  {
    atoms: [a],
    decode: head => {
      if head.request.body is Empty {
        raise fail(a, missing())
      }
      if !content_type_matches(head, "multipart/form-data") {
        raise fail(
          a,
          unsupported_media_type(
            head.request.headers.get("content-type").unwrap_or(""),
          ),
        )
      }
      let boundary = @multipart.parse_boundary(
        head.request.headers.get("content-type").unwrap_or(""),
      ) catch {
        _ =>
          raise fail(
            a,
            @schema.DecodeFailure(
              kind=Malformed,
              message="invalid multipart boundary",
            ),
          )
      }
      Staged::after_body(body => {
        guard body is Buffered(bytes) else { raise fail(a, missing()) }
        let parts = @multipart.parse(
          bytes,
          boundary,
          max_parts~,
          max_header_bytes~,
          max_part_bytes~,
        ) catch {
          @mttp_core.TransportError(kind~, detail~, ..) =>
            raise fail(
              a,
              @schema.DecodeFailure(
                kind=match kind {
                  TooLarge(limit~) => @schema.TooLarge(limit~)
                  _ => @schema.Malformed
                },
                message=detail,
              ),
            )
        }
        (codec.decode_)(parts) catch {
          error => raise fail(a, error)
        }
      })
    },
    encode: (value, sink) => {
      let boundary = @multipart.make_boundary(@rt.default_random)
      let (content_type, body) = try! @multipart.encode_body(
        (codec.encode_)(value),
        boundary,
      )
      sink.headers = sink.headers.set("content-type", content_type)
      sink.body = body
    },
  }
}

///|
/// Makes omitted fields optional without hiding malformed or duplicate parts.
pub fn[T] MultipartCodec::optional(
  self : MultipartCodec[T],
) -> MultipartCodec[T?] {
  let fields = match self.schema_.json {
    Object(fields) => fields.copy()
    _ => Map([])
  }
  fields["required"] = []
  MultipartCodec::new(
    { ..self.schema_, json: Json(fields), },
    parts => {
      if self.schema_.json is { "properties": Object(fields), .. } &&
        fields.keys().all(name => !parts.iter().any(part => part.name == name)) {
        return None
      }
      Some((self.decode_)(parts)) catch {
        @schema.DecodeFailure(kind=Missing, ..) => None
        error => raise error
      }
    },
    value => {
      match value {
        None => []
        Some(value) => (self.encode_)(value)
      }
    },
  )
}

///|
/// Maps a whole form to an application type, preserving its field schema.
pub fn[T, U] MultipartCodec::map(
  self : MultipartCodec[T],
  to : (T) -> U raise @schema.DecodeFailure,
  from : (U) -> T,
) -> MultipartCodec[U] {
  MultipartCodec::new(self.schema_, parts => to((self.decode_)(parts)), value => {
    (self.encode_)(from(value))
  })
}
