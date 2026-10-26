///|
/// Pairs outputs with a runtime HTTP status. The client returns the received
/// status; API documentation uses a default response. Invalid status values
/// use the server's unhandled-error policy.
pub fn[T, M] Out::and_status(self : Out[T, M]) -> Out[(T, Int32), M] {
  {
    mode: self.mode,
    variants: self.variants.map(variant => variant.and_status()),
  }
}

///|
/// Adds a runtime status to one variant so it can participate in a typed
/// output union before being combined with other variants.
pub fn[T] Variant::and_status(self : Variant[T]) -> Variant[(T, Int32)] {
  {
    status: self.status,
    status_of: Some(value => value.1),
    dynamic_media: self.dynamic_media,
    matches: value => (self.matches)(value.0),
    media_type: self.media_type,
    schema: self.schema,
    headers: self.headers,
    header_schemas: self.header_schemas,
    description: self.description,
    encode: value => (self.encode)(value.0),
    decode_bytes: self.decode_bytes.map(decode => {
      (head, bytes) => (decode(head, bytes), head.status)
    }),
    decode_stream: self.decode_stream.map(decode => {
      (head, stream) => (decode(head, stream), head.status)
    }),
  }
}

///|
/// A buffered response whose content type is computed with its bytes, for
/// example a multipart reply carrying a generated boundary parameter.
pub fn body_out(
  status~ : Int32 = 200,
) -> Out[(String, Bytes), @client.Buffered] {
  let variant : Variant[(String, Bytes)] = {
    status,
    status_of: None,
    dynamic_media: true,
    matches: _ => true,
    media_type: None,
    schema: Some(@schema.raw_bytes.schema()),
    headers: [],
    header_schemas: {},
    description: "buffered response with a dynamic content type",
    encode: value => {
      (@model.Headers::of([("content-type", value.0)]), Bytes(value.1))
    },
    decode_bytes: Some((head, bytes) => {
      guard head.headers.get("content-type") is Some(media_type) else {
        raise DecodeError(head, message="missing content-type", body=bytes)
      }
      (media_type, bytes)
    }),
    decode_stream: None,
  }
  { mode: @client.Buffered::{ }, variants: [variant], }
}

///|
/// A response with optional dynamic content type and a buffered or streamed
/// body. Server encoding transfers body ownership without concatenating it.
/// `call` buffers within the client's limit; `call_with` borrows a stream only
/// for the callback's lifetime, which ends by closing that stream.
pub fn stream_body_out(
  status~ : Int32 = 200,
) -> Out[(String?, @model.Body), @client.Buffered] {
  let variant : Variant[(String?, @model.Body)] = {
    status,
    status_of: None,
    dynamic_media: true,
    matches: _ => true,
    media_type: None,
    schema: Some(@schema.raw_bytes.schema()),
    headers: [],
    header_schemas: {},
    description: "response body with an optional dynamic content type",
    encode: value => {
      let headers = match value.0 {
        Some(media_type) => @model.Headers::of([("content-type", media_type)])
        None => @model.Headers::empty()
      }
      (headers, value.1)
    },
    decode_bytes: Some((head, bytes) => {
      (head.headers.get("content-type"), @model.Bytes(bytes))
    }),
    decode_stream: Some((head, stream) => {
      (
        head.headers.get("content-type"),
        @model.Stream(@model.StreamBody::new(stream)),
      )
    }),
  }
  { mode: @client.Buffered::{ }, variants: [variant], }
}

///|
/// Adds a named Set-Cookie field. The paired string is the value and optional
/// attributes (for example `abc; Secure; HttpOnly`); callers supply valid cookie
/// syntax. Unlike ordinary headers, repeated Set-Cookie fields stay separate.
pub fn[T, M] Out::set_cookie(
  self : Out[T, M],
  name : String,
) -> Out[(T, String), M] {
  let codec = @schema.TextCodec::new(
    raw => {
      guard raw.has_prefix(name + "=") else { raise mismatch("named cookie") }
      raw[name.length() + 1:].to_owned()
    },
    value => name + "=" + value,
    @schema.string.schema(),
  )
  {
    mode: self.mode,
    variants: self.variants.map(variant => {
      let paired = variant.and_header("set-cookie", codec)
      let select = (head : @model.ResponseHead) => {
        let values = head.headers
          .get_all("set-cookie")
          .filter(raw => raw.has_prefix(name + "="))
        guard values is [raw] else {
          raise DecodeError(
            head,
            message="missing or repeated cookie " + name,
            body=b"",
          )
        }
        codec.decode(raw) catch {
          error => raise DecodeError(head, message=error.message(), body=b"")
        }
      }
      {
        ..paired,
        decode_bytes: variant.decode_bytes.map(decode => {
          (head, bytes) => (decode(head, bytes), select(head))
        }),
        decode_stream: variant.decode_stream.map(decode => {
          (head, stream) => {
            let cookie = select(head)
            (decode(head, stream), cookie)
          }
        }),
      }
    }),
  }
}
