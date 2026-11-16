///|
priv struct DecodedBody {
  read : async () -> Bytes? raise @mttp_core.TransportError
  close_ : () -> Unit
  decoder : ContentDecoder
  mut closed : Bool
}

///|
impl @mttp_core.BodyStream for DecodedBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @mttp_core.BodyStream::close(self)
  let bytes = read_decoded(() => (self.read)(), Some(self.decoder)) catch {
    @mttp_core.TransportError(..) as error => raise error
    _ =>
      raise @mttp_core.TransportError(
        kind=Protocol,
        phase=Body,
        detail="content decoding failed",
      )
  }
  if bytes is None {
    @mttp_core.BodyStream::close(self)
  }
  bytes
}

///|
impl @mttp_core.BodyStream for DecodedBody with fn close(self) {
  if !self.closed {
    self.closed = true
    (self.close_)()
    for stage in self.decoder.stages {
      stage.input = b""[:]
      stage.deferred = b""[:]
      stage.sniffed = b""
    }
  }
}

///|
/// A body read through while it is collected, up to `limit` bytes, for the
/// dictionary store; at a clean end the whole body is offered.
priv struct CollectedBody {
  read : async () -> Bytes? raise @mttp_core.TransportError
  close_ : () -> Unit
  // The bytes read so far: chunks of 64 KiB or more as they came, smaller
  // ones gathered into blocks of 64 KiB, so neither a growing buffer nor a
  // body of one-byte chunks holds much more than the bytes themselves.
  // Dropped as soon as they cannot become a dictionary.
  mut collected : Array[Bytes]
  mut collected_bytes : Int32
  mut block : Buffer
  limit : Int32
  mut over : Bool
  on_end : (Bytes) -> Unit
  mut closed : Bool
}

///|
/// The size small chunks are gathered into while a body is collected.
let collected_block_bytes : Int32 = 64 * 1024

///|
fn CollectedBody::flush_block(self : CollectedBody) -> Unit {
  if self.block.length() > 0 {
    self.collected.push(self.block.to_bytes())
    self.block = Buffer(size_hint=collected_block_bytes)
  }
}

///|
impl @mttp_core.BodyStream for CollectedBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @mttp_core.BodyStream::close(self)
  let bytes = (self.read)()
  match bytes {
    Some(chunk) =>
      if !self.over {
        // Compared as a difference, so a limit near Int's top cannot wrap.
        if chunk.length() > self.limit - self.collected_bytes {
          // Too large to be a dictionary: stop holding it.
          self.over = true
          self.collected = []
          self.collected_bytes = 0
          self.block = Buffer(size_hint=0)
        } else {
          self.collected_bytes += chunk.length()
          if chunk.length() >= collected_block_bytes {
            self.flush_block()
            self.collected.push(chunk)
          } else {
            self.block.write_bytes(chunk)
            if self.block.length() >= collected_block_bytes {
              self.flush_block()
            }
          }
        }
      }
    None => {
      // Only a body read to its end becomes a dictionary.
      if !self.over {
        self.flush_block()
        let body = Buffer(size_hint=self.collected_bytes)
        for part in self.collected {
          body.write_bytes(part)
        }
        self.collected = []
        (self.on_end)(body.to_bytes())
      }
      @mttp_core.BodyStream::close(self)
    }
  }
  bytes
}

///|
impl @mttp_core.BodyStream for CollectedBody with fn close(self) {
  if !self.closed {
    self.closed = true
    self.collected = []
    self.collected_bytes = 0
    self.block = Buffer(size_hint=0)
    (self.close_)()
  }
}

///|
/// A backend that negotiates and lazily undoes content codings. Any caller
/// supplied Accept-Encoding opts out, including identity. SendOptions are
/// passed unchanged: the inner engine bounds wire bytes, readers bound decoded
/// bytes. Each decoded slice is at most 64 KiB.
///
/// Given a dictionary store, it also does RFC 9842's client side: a request
/// the store has a dictionary for advertises it with `Available-Dictionary`
/// and `Dictionary-ID` and adds `dcb` and `dcz` to `Accept-Encoding`; a
/// response coded with one is decoded with that dictionary once its header
/// names it; and a 200 response with `Use-As-Dictionary` is offered to the
/// store when its body has been read to the end.
pub struct Decompress {
  priv inner : &@mttp_core.Backend
  priv dictionaries : @dictionary.DictionaryStore?
  priv partition : String
  priv mut closed : Bool
}

///|
/// Wraps inner, transferring backend closure to this wrapper. With
/// `dictionaries`, requests use and responses fill that store, in
/// `partition`.
pub fn Decompress::new(
  inner : &@mttp_core.Backend,
  dictionaries? : @dictionary.DictionaryStore,
  partition~ : String = "",
) -> Decompress {
  { inner, dictionaries, partition, closed: false, }
}

///|
/// Makes the Backend operations available as methods.
pub extend Decompress with @mttp_core.Backend::{send, close}

///|
/// Validates before delegating, then transfers the received body to a lazy
/// decoded stream when this wrapper negotiated its encoding.
pub impl @mttp_core.Backend for Decompress with fn send(self, request, options) {
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend closed",
    )
  }
  request.validate()
  options.validate()
  let decode = !request.headers.contains("accept-encoding")
  let url = Some(@mttp_core.Url::parse(request.url)) catch { _ => None }
  // The store's dictionary for this request, unless the caller chose the
  // dictionary headers or the codings itself.
  let offered = match (self.dictionaries, url) {
    (Some(store), Some(u)) if decode &&
      !request.headers.contains("available-dictionary") =>
      store.select(u, partition=self.partition)
    _ => None
  }
  let request_time_ms = match self.dictionaries {
    Some(store) => store.now_unix_ms()
    None => 0L
  }
  let sent = if decode {
    request.set_header(
      "accept-encoding",
      accept_encoding(dictionary=offered is Some(_)),
    )
  } else {
    request
  }
  let sent = match offered {
    Some(d) => {
      let with_hash = sent.set_header(
        "available-dictionary",
        d.available_dictionary(),
      )
      match d.dictionary_id() {
        Some(id) => with_hash.set_header("dictionary-id", id)
        None => with_hash
      }
    }
    None => sent
  }
  let response = self.inner.send(sent, options)
  errdefer {
    @rt.close_unclaimed(response.attributes)
    response.close()
  }
  if !has_body(request.meth.to_string(), response.status) {
    return response
  }
  let response = if decode {
    let (head, decoder) = decode_head(response.head(), dictionary?=offered)
    match decoder {
      Some(decoder) => {
        let (read, close_) = body_source(response.body)
        {
          ..response,
          headers: head.headers,
          body: Stream(
            @mttp_core.StreamBody::new(DecodedBody::{
              read,
              close_,
              decoder,
              closed: false,
            }),
          ),
        }
      }
      None => response
    }
  } else {
    response
  }
  // A dictionary is the decoded body, so only a response read in full, with
  // no coding left on it, can become one.
  match (self.dictionaries, url) {
    (Some(store), Some(u)) if response.status == 200 &&
      response.headers.contains("use-as-dictionary") &&
      !response.headers.contains("content-encoding") => {
      let (read, close_) = body_source(response.body)
      let headers = response.headers
      let partition = self.partition
      {
        ..response,
        body: Stream(
          @mttp_core.StreamBody::new(CollectedBody::{
            read,
            close_,
            collected: [],
            collected_bytes: 0,
            block: Buffer(size_hint=0),
            limit: store.max_dictionary_bytes(),
            over: false,
            on_end: body => {
              store.offer(u, headers, body, request_time_ms~, partition~)
              |> ignore
            },
            closed: false,
          }),
        ),
      }
    }
    _ => response
  }
}

///|
/// Closes the inner backend exactly once and refuses subsequent sends.
pub impl @mttp_core.Backend for Decompress with fn close(self) {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}
