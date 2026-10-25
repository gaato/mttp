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
  priv mut failure : @model.TransportError?
}

///|
/// Creates gzip, zlib-wrapped deflate, or Brotli compression. Zstd encoding
/// is unavailable in the codec dependency and raises Invalid before allocation.
/// Brotli uses a 22-bit window; gzip and deflate use a 32 KiB history window.
pub fn ContentEncoder::new(
  coding : Coding,
) -> ContentEncoder raise @model.TransportError {
  let encoder : &@codec_bytes.Encode = match coding {
    Gzip => (@gzip.Encoder() : &@codec_bytes.Encode)
    Deflate => @zlib.Encoder()
    Brotli => @brotli.Encoder(window_bits=22)
    Zstd => raise encoder_misuse("zstd encoding is unavailable")
  }
  {
    encoder,
    input: b""[:],
    output: FixedArray::make(65536, b'\x00'),
    waiting: true,
    ended: false,
    done: false,
    failure: None,
  }
}

///|
/// Supplies one caller-owned input chunk after NeedInput. An empty chunk is
/// allowed; overwriting unconsumed input or feeding after EOF raises Invalid.
pub fn ContentEncoder::feed(
  self : ContentEncoder,
  bytes : Bytes,
) -> Unit raise @model.TransportError {
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
) -> Unit raise @model.TransportError {
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
) -> Pulled raise @model.TransportError {
  if self.failure is Some(error) {
    raise error
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
        let failure = @model.TransportError(
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
fn encoder_misuse(detail : String) -> @model.TransportError {
  @model.TransportError(kind=Invalid, phase=Body, detail~)
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
