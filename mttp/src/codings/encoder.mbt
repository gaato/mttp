///|
/// Incremental response compression with at most 64 KiB returned per pull.
/// Feed only after NeedInput, and end after the final NeedInput. Each input
/// chunk is sync-flushed so a live event stream does not wait for later input.
/// The caller owns and bounds input chunks; one chunk is retained at a time.
pub struct ContentEncoder {
  priv encoder : &@codec_bytes.Encode
  priv mut input : BytesView
  priv output : FixedArray[Byte]
  priv mut waiting : Bool
  priv mut ended : Bool
  priv mut done : Bool
  priv mut failure : @mttp_core.TransportError?
  // The dcb or dcz header, sent before the first compressed byte.
  priv mut prefix : Bytes
}

///|
/// Creates gzip, zlib-wrapped deflate, Brotli or zstd compression, or with
/// `dictionary` RFC 9842's `dcb` or `dcz`. Brotli and `dcb` use a 22-bit
/// window, within the 16 MB RFC 9842 allows `dcb`; gzip and deflate use a 32
/// KiB history window; zstd and `dcz` are level 3, whose window for a stream
/// of unknown length is 2 MiB, within the 8 MB RFC 9659 and RFC 9842 let
/// them use. `dcb` or `dcz` without a dictionary cannot be written: the
/// first `pull` raises `Invalid`.
pub fn ContentEncoder::new(
  coding : Coding,
  dictionary? : ServerDictionary,
) -> ContentEncoder {
  let mut failure = None
  let encoder : &@codec_bytes.Encode = match (coding, dictionary) {
    (Gzip, _) => (@gzip.Encoder() : &@codec_bytes.Encode)
    (Deflate, _) => @zlib.Encoder()
    (Brotli, _) => @brotli.Encoder(window_bits=22)
    (Zstd, _) => @zstd.Encoder(level=3)
    (Dcb, Some(d)) => @brotli.Encoder(window_bits=22, dictionary=d.brotli)
    (Dcz, Some(d)) => @zstd.Encoder(level=3, dictionary=d.zstd)
    (Dcb | Dcz, None) => {
      failure = Some(encoder_misuse("\{coding.name()} needs a dictionary"))
      @zstd.Encoder(level=3)
    }
  }
  let prefix = match (coding, dictionary) {
    (Dcb, Some(d)) => dcb_magic + d.hash
    (Dcz, Some(d)) => dcz_magic + d.hash
    _ => b""
  }
  {
    encoder,
    input: b""[:],
    output: FixedArray::make(65536, b'\x00'),
    waiting: true,
    ended: false,
    done: false,
    failure,
    prefix,
  }
}

///|
/// Supplies one caller-owned input chunk after NeedInput. An empty chunk is
/// allowed; overwriting unconsumed input or feeding after EOF raises Invalid.
pub fn ContentEncoder::feed(
  self : ContentEncoder,
  bytes : Bytes,
) -> Unit raise @mttp_core.TransportError {
  if self.failure is Some(error) {
    raise error
  }
  if !self.waiting || self.ended {
    raise encoder_misuse("feed requires NeedInput before EOF")
  }
  self.input = bytes[:]
  self.waiting = false
}

///|
/// Finishes the compressed stream after NeedInput. Repeated end is harmless.
pub fn ContentEncoder::end(
  self : ContentEncoder,
) -> Unit raise @mttp_core.TransportError {
  if self.failure is Some(error) {
    raise error
  }
  if self.ended {
    return
  }
  if !self.waiting {
    raise encoder_misuse("end requires NeedInput")
  }
  self.ended = true
  self.waiting = false
}

///|
/// Returns a nonempty encoded slice, NeedInput, or sticky Done. Codec failures
/// become sticky Protocol errors; no further input is accepted after failure.
pub fn ContentEncoder::pull(
  self : ContentEncoder,
) -> Pulled raise @mttp_core.TransportError {
  if self.failure is Some(error) {
    raise error
  }
  if self.prefix.length() > 0 {
    let header = self.prefix
    self.prefix = b""
    return Slice(header)
  }
  if self.done {
    return Done
  }
  if self.waiting {
    return NeedInput
  }
  for ;; {
    let status = self.encoder.step(
      self.input,
      self.output.mut_view(),
      action=if self.ended { Finish } else { Flush },
    ) catch {
      CodecError(_, message) => {
        let failure = @mttp_core.TransportError(
          kind=Protocol,
          phase=Body,
          detail="content encoding failed: " + message,
        )
        self.failure = Some(failure)
        self.input = b""[:]
        raise failure
      }
    }
    self.input = self.input[self.encoder.last_consumed():]
    self.waiting = status is NeedMoreInput
    self.done = status is Done
    let count = self.encoder.last_produced()
    if count > 0 {
      return Slice(Bytes::from_array(self.output[:count]))
    }
    if self.done {
      return Done
    }
    if self.waiting {
      return NeedInput
    }
  }
}

///|
fn encoder_misuse(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Invalid, phase=Body, detail~)
}

///|
/// Pulls compressed output with backpressure, fetching upstream only when
/// the encoder needs input. The caller owns and closes the upstream reader.
pub async fn read_encoded(
  read : async () -> Bytes?,
  encoder : ContentEncoder,
) -> Bytes? {
  for ;; {
    match encoder.pull() {
      Slice(bytes) => return Some(bytes)
      Done => return None
      NeedInput =>
        match read() {
          Some(bytes) => encoder.feed(bytes)
          None => encoder.end()
        }
    }
  }
}
