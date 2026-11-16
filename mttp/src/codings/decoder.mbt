///|
/// The largest slice one `ContentDecoder::pull` returns, so a decoded read is
/// no larger than a plain one (`max_read_bytes`) however well the body packs.
let decoded_slice_bytes : Int32 = 64 * 1024

///|
/// The largest `br` window accepted, as a power of two: RFC 7932's largest,
/// 16 MiB, as browsers accept, since a smaller cap refuses valid streams.
/// The decoder grows the window only as output needs it, so a stream that
/// declares 16 MiB and decodes to little holds little.
let brotli_window_bits : Int32 = 24

///|
/// The largest `zstd` window accepted, as a power of two: 8 MiB, which RFC
/// 9659 requires HTTP recipients to accept and encoders not to exceed for
/// the `zstd` coding. As for `br`, the window grows only as output needs it.
let zstd_window_bits : Int32 = 23

///|
/// The largest `dcz` window accepted, as a power of two, before the
/// dictionary is counted: 8 MiB, RFC 9842 section 5's floor.
let dcz_min_window_bits : Int32 = 23

///|
/// The largest window RFC 9842 section 5 lets a `dcz` stream ask for:
/// 128 MiB.
let dcz_max_window_bits : Int32 = 27

///|
/// The `zstd` window a `dcz` decoder accepts with a dictionary of `length`
/// bytes: at least 8 MiB or 1.25 times the dictionary, whichever is greater,
/// as RFC 9842 section 5 requires, rounded up to a power of two and at most
/// 128 MiB.
fn dcz_window_bits(length : Int32) -> Int32 {
  let need = (length.to_int64() * 5L + 3L) / 4L
  let mut bits = dcz_min_window_bits
  while bits < dcz_max_window_bits && 1L << bits < need {
    bits += 1
  }
  bits
}

///|
/// The fixed header before a `dcb` stream: a magic number, then the
/// dictionary's SHA-256 (RFC 9842 section 4).
let dcb_magic : Bytes = b"\xff\x44\x43\x42"

///|
/// The fixed header before a `dcz` stream: a Zstandard skippable frame of 32
/// bytes holding the dictionary's SHA-256 (RFC 9842 section 5).
let dcz_magic : Bytes = b"\x5e\x2a\x4d\x18\x20\x00\x00\x00"

///|
/// One coding being undone. Its input is the previous stage's output, or the
/// wire for the first stage.
priv struct Stage {
  coding : Coding
  /// `None` for a `deflate` body until its first two bytes, which tell zlib
  /// from raw DEFLATE, have arrived, and for `dcb` and `dcz` until their
  /// header has, and named the dictionary.
  mut decoder : &@codec_bytes.Decode?
  /// The bytes of a `deflate` body or a `dcb`/`dcz` header seen before that.
  mut sniffed : Bytes
  /// Input accepted from upstream and not yet consumed.
  mut input : BytesView
  /// Input that waits while a held `deflate` byte goes to the decoder first,
  /// so the chunk after it is not copied to join them.
  mut deferred : BytesView
  /// Upstream has nothing more.
  mut input_ended : Bool
  /// Some input has arrived.
  mut started : Bool
  /// The coded stream reached its end, and nothing followed it.
  mut finished : Bool
  /// The last step stopped for output room: the decoder may have taken all
  /// the input and still hold decoded bytes, so step again before asking
  /// upstream for more.
  mut output_pending : Bool
  /// The error of a step that wrote output before it raised. That output
  /// goes out as a slice and the error on the next pull, so what a stream's
  /// reader gets before the error does not depend on how the wire is chunked.
  mut failure : @mttp_core.TransportError?
  output : FixedArray[Byte]
}

///|
/// Undoes a chain of content codings incrementally. The caller pulls decoded
/// slices; when `pull` answers `NeedInput` it feeds the next wire chunk, or
/// ends the input. Memory is bounded whatever the body: per stage, a
/// `decoded_slice_bytes` output buffer and the decoder's state, which for
/// gzip and `deflate` is gaato/deflate's 32 KiB window and tables (74,240
/// bytes; a gzip header's extra field, name and comment are skipped, not
/// held), for `br` a window of at most `1 << brotli_window_bits` bytes, never
/// more than the stage's output so far, and at most 1.3 MiB of tables, and
/// for `zstd` a window of at most `1 << zstd_window_bits` bytes, likewise no
/// more than the output so far, one block of at most 128 KiB and its
/// literals, and about 11 KiB of tables. Each slice is a fresh `Bytes` of at
/// most `decoded_slice_bytes`.
pub struct ContentDecoder {
  /// The first stage reads the wire; each later one reads the stage before.
  priv stages : Array[Stage]
  priv mut waiting : Bool
  priv mut ended : Bool
  priv mut failure : @mttp_core.TransportError?
  // The dictionary the request offered, for dcb and dcz stages.
  priv dictionary : @dictionary.Dictionary?
}

///|
/// What one `pull` produced.
#non_exhaustive
pub(all) enum Pulled {
  /// A decoded slice, never empty.
  Slice(Bytes)
  /// Feed a wire chunk, or end the input, then pull again.
  NeedInput
  /// The body is decoded in full, and nothing followed it.
  Done
}

///|
/// A decoder that undoes `undo`, last applied coding first. One to five
/// codings are required; an empty or oversized plan raises Invalid.
pub fn ContentDecoder::new(
  undo : Array[Coding],
  dictionary? : @dictionary.Dictionary,
) -> ContentDecoder raise @mttp_core.TransportError {
  if undo.is_empty() || undo.length() > max_content_codings {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Body,
      detail="decoder needs one to five codings",
    )
  }
  for coding in undo {
    // A dictionary coding the request did not offer a dictionary for, or
    // two of them, cannot be undone: each names the one dictionary offered.
    if coding is (Dcb | Dcz) && dictionary is None {
      raise @mttp_core.TransportError(
        kind=Protocol,
        phase=Body,
        detail="response is \{coding.name()}-coded, but the request offered no dictionary",
      )
    }
  }
  let stages = undo.map(coding => {
    coding,
    decoder: match coding {
      Gzip => Some(@gzip.Decoder(keep_header=false))
      Deflate | Dcb | Dcz => None
      Brotli => Some(@brotli.Decoder(max_window_bits=brotli_window_bits))
      Zstd => Some(@zstd.Decoder(max_window_bits=zstd_window_bits))
    },
    sniffed: b"",
    input: b""[:],
    deferred: b""[:],
    input_ended: false,
    started: false,
    finished: false,
    output_pending: false,
    failure: None,
    output: FixedArray::make(decoded_slice_bytes, b'\x00'),
  })
  { stages, waiting: true, ended: false, failure: None, dictionary, }
}

///|
/// Hands the decoder the next wire chunk, after `pull` answered `NeedInput`.
/// Retains this caller-owned chunk until consumed. Refuses overwriting unread
/// input and feeding after EOF. The caller bounds wire chunk size.
pub fn ContentDecoder::feed(
  self : ContentDecoder,
  chunk : Bytes,
) -> Unit raise @mttp_core.TransportError {
  if self.failure is Some(error) {
    raise error
  }
  if !self.waiting || self.ended {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Body,
      detail="feed requires NeedInput before EOF",
    )
  }
  self.waiting = false
  self.stages[0].input = chunk[:]
}

///|
/// Tells the decoder the wire has nothing more, after `pull` answered
/// `NeedInput`.
/// Repeated end calls are harmless. Ending before NeedInput is refused.
pub fn ContentDecoder::end(
  self : ContentDecoder,
) -> Unit raise @mttp_core.TransportError {
  if self.failure is Some(error) {
    raise error
  }
  if self.ended {
    return
  }
  if !self.waiting {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Body,
      detail="end requires NeedInput",
    )
  }
  self.ended = true
  self.waiting = false
  self.stages[0].input_ended = true
}

///|
/// The next decoded slice, or what the decoder needs before it can tell.
/// Corrupt, truncated or trailing coded data raises `Protocol`, after the
/// slices decoded before it.
/// The synchronous catch retains the exact failure for subsequent calls.
#warnings("-fragile_catch_all")
pub fn ContentDecoder::pull(
  self : ContentDecoder,
) -> Pulled raise @mttp_core.TransportError {
  if self.failure is Some(error) {
    raise error
  }
  let pulled = self.pull_stage(self.stages.length() - 1) catch {
    error => {
      self.failure = Some(error)
      raise error
    }
  }
  self.waiting = pulled is NeedInput
  pulled
}

///|
/// Each stage's decoder keeps gaato/codec_bytes' rules: a step that answers
/// `NeedMoreInput` took all its input and wrote everything that input
/// determines, `NeedMoreOutput` means the slice is full, and `Done` comes
/// only with the input ended and nothing after the stream, whose bytes the
/// decoder refuses itself. So the loop cannot spin.
fn ContentDecoder::pull_stage(
  self : ContentDecoder,
  index : Int32,
) -> Pulled raise @mttp_core.TransportError {
  let stage = self.stages[index]
  if stage.failure is Some(error) {
    raise error
  }
  for ;; {
    if stage.finished {
      return Done
    }
    if stage.input.length() == 0 && stage.deferred.length() > 0 {
      stage.input = stage.deferred
      stage.deferred = b""[:]
    }
    if stage.input.length() == 0 && !stage.input_ended && !stage.output_pending {
      if index == 0 {
        return NeedInput
      }
      match self.pull_stage(index - 1) {
        Slice(slice) => stage.input = slice[:]
        NeedInput => return NeedInput
        Done => stage.input_ended = true
      }
    }
    if !stage.started {
      // An empty body, as for HEAD, 204 or 304, is empty in any coding but
      // dcb and dcz, whose fixed header RFC 9842 always requires.
      if stage.input.length() == 0 && !(stage.coding is (Dcb | Dcz)) {
        stage.finished = true
        continue
      }
      stage.started = true
    }
    let decoder = match stage.decoder {
      Some(decoder) => decoder
      None if stage.coding is (Dcb | Dcz) => {
        let magic = if stage.coding is Dcb { dcb_magic } else { dcz_magic }
        let header_length = magic.length() + 32
        // Only the header is copied; the rest stays a view of the chunk.
        let take = (header_length - stage.sniffed.length()).min(
          stage.input.length(),
        )
        let joined = stage.sniffed + stage.input[:take].to_owned()
        stage.input = stage.input[take:]
        if joined.length() < header_length {
          guard stage.input_ended else {
            stage.sniffed = joined
            continue
          }
          raise malformed(stage.coding, "header cut short")
        }
        // ContentDecoder::new refused these codings without a dictionary.
        let dictionary = self.dictionary.unwrap()
        guard joined[:magic.length()] == magic[:] else {
          raise malformed(stage.coding, "wrong magic number")
        }
        // RFC 9842 has the hash checked before the dictionary is used.
        guard joined[magic.length():header_length] == dictionary.hash[:] else {
          raise malformed(
            stage.coding,
            "names a dictionary other than the one offered",
          )
        }
        let decoder : &@codec_bytes.Decode = if stage.coding is Dcb {
          (
            @brotli.Decoder(
              max_window_bits=brotli_window_bits,
              dictionary=@brotli.Dictionary(dictionary.content),
            ) : &@codec_bytes.Decode)
        } else {
          (
            @zstd.Decoder(
              max_window_bits=dcz_window_bits(dictionary.content.length()),
              dictionary=@zstd.Dictionary::raw(dictionary.content),
            ) : &@codec_bytes.Decode)
        }
        stage.decoder = Some(decoder)
        stage.sniffed = b""
        decoder
      }
      None => {
        // The two bytes that tell zlib from raw DEFLATE, read in place: a
        // first chunk of one byte is held, never joined to the next chunk.
        let held = stage.sniffed.length()
        // Compared as a difference: a chunk near Int's top cannot wrap it.
        if stage.input.length() < 2 - held && !stage.input_ended {
          stage.sniffed = stage.sniffed + stage.input.to_owned()
          stage.input = b""[:]
          continue
        }
        let first = if held > 0 { stage.sniffed[0] } else { stage.input[0] }
        let second = if held > 0 {
          stage.input.get(0)
        } else {
          stage.input.get(1)
        }
        let decoder = if second is Some(second) &&
          @zlib.is_header(first, second) {
          (@zlib.Decoder() : &@codec_bytes.Decode)
        } else {
          // Raw DEFLATE, which also refuses a body of one byte as cut short.
          @deflate.Decoder()
        }
        stage.decoder = Some(decoder)
        if held > 0 {
          // The held byte goes first; the chunk waits for it, uncopied.
          stage.deferred = stage.input
          stage.input = stage.sniffed[:]
        }
        stage.sniffed = b""
        decoder
      }
    }
    let status = decoder.step(
      stage.input,
      stage.output.mut_view(),
      end=stage.input_ended && stage.deferred.length() == 0,
    ) catch {
      CodecError(_, message) => {
        let error = malformed(stage.coding, message)
        let produced = decoder.last_produced()
        guard produced > 0 else { raise error }
        stage.failure = Some(error)
        return Slice(Bytes::from_array(stage.output[:produced]))
      }
    }
    stage.input = stage.input[decoder.last_consumed():]
    stage.output_pending = status is NeedMoreOutput
    stage.finished = status is Done
    let produced = decoder.last_produced()
    if produced > 0 {
      return Slice(Bytes::from_array(stage.output[:produced]))
    }
  }
}

///|
fn malformed(coding : Coding, message : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=Protocol,
    phase=Body,
    detail="malformed \{coding.name()} response body: \{message}",
  )
}
