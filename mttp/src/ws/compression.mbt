///|
priv struct DeflateParams {
  server_no : Bool
  client_no : Bool
  server_window : Int32?
  client_window : Int32?
}

///|
fn compression_error(detail : String) -> @core_ws.WsError {
  @core_ws.WsError(kind=Handshake(status=101), detail~)
}

///|
fn window_bits(value : String?) -> Int32? {
  match value {
    Some("8") => Some(8)
    Some("9") => Some(9)
    Some("10") => Some(10)
    Some("11") => Some(11)
    Some("12") => Some(12)
    Some("13") => Some(13)
    Some("14") => Some(14)
    Some("15") => Some(15)
    _ => None
  }
}

///|
// Names are case-sensitive extension tokens, as in RFC 7692's ABNF.
fn deflate_params(
  extension : @handshake.Extension,
  response~ : Bool,
) -> DeflateParams? {
  let seen : Map[String, Bool] = Map([])
  let mut server_no = false
  let mut client_no = false
  let mut server_window = None
  let mut client_window = None
  for param in extension.params {
    if seen.contains(param.name) {
      return None
    }
    seen[param.name] = true
    match param.name {
      "server_no_context_takeover" => {
        if param.value is Some(_) {
          return None
        }
        server_no = true
      }
      "client_no_context_takeover" => {
        if param.value is Some(_) {
          return None
        }
        client_no = true
      }
      "server_max_window_bits" => {
        guard window_bits(param.value) is Some(bits) else { return None }
        server_window = Some(bits)
      }
      "client_max_window_bits" => {
        if !response && param.value is None {
          continue
        }
        guard window_bits(param.value) is Some(bits) else { return None }
        client_window = Some(bits)
      }
      _ => return None
    }
  }
  Some({ server_no, client_no, server_window, client_window, })
}

///|
fn Compression::accept(
  self : Compression,
  offers : Array[@handshake.Extension],
) -> (@handshake.Extension, &@core_ws.Extension)? {
  for offer in offers {
    if offer.name != "permessage-deflate" {
      continue
    }
    guard deflate_params(offer, response=false) is Some(params) else {
      continue
    }
    // This is a constraint on our encoder, unlike client_window (a hint).
    if params.server_window is Some(bits) && bits < 15 {
      continue
    }
    let server_no = params.server_no || self.server_no_context_takeover
    let client_no = params.client_no || self.client_no_context_takeover
    let selected : Array[@handshake.ExtensionParam] = []
    if server_no {
      selected.push({ name: "server_no_context_takeover", value: None, })
    }
    if client_no {
      selected.push({ name: "client_no_context_takeover", value: None, })
    }
    if params.server_window is Some(_) {
      selected.push({ name: "server_max_window_bits", value: Some("15"), })
    }
    // We can always decode with 32 KiB, so need not echo a client's hint.
    return Some(
      (
        { name: "permessage-deflate", params: selected, },
        PerMessageDeflate::new(encode_reset=server_no, decode_reset=client_no),
      ),
    )
  }
  None
}

///|
fn Compression::validate(
  self : Compression,
  selected : Array[@handshake.Extension],
) -> &@core_ws.Extension? raise @core_ws.WsError {
  if selected.is_empty() {
    return None
  }
  guard selected is [extension] && extension.name == "permessage-deflate" else {
    raise compression_error("multiple or unsupported compression responses")
  }
  guard deflate_params(extension, response=true) is Some(params) else {
    raise compression_error("invalid permessage-deflate response parameters")
  }
  if self.server_no_context_takeover && !params.server_no {
    raise compression_error("server ignored server_no_context_takeover")
  }
  if params.client_window is Some(bits) && bits < 15 {
    raise compression_error("client encoder requires window 15")
  }
  Some(
    PerMessageDeflate::new(
      encode_reset=params.client_no || self.client_no_context_takeover,
      decode_reset=params.server_no,
    ),
  )
}

///|
priv struct PerMessageDeflate {
  encoder : @deflate.Encoder
  encode_reset : Bool
  decode_reset : Bool
  mut history : Bytes
}

///|
fn PerMessageDeflate::new(
  encode_reset~ : Bool,
  decode_reset~ : Bool,
) -> PerMessageDeflate {
  // Level 1 keeps interactive messages inexpensive while retaining the same
  // RFC 1951 window and all negotiated context semantics.
  {
    encoder: @deflate.Encoder(level=1),
    encode_reset,
    decode_reset,
    history: b"",
  }
}

///|
impl @core_ws.Extension for PerMessageDeflate with fn name(_) {
  "permessage-deflate"
}

///|
impl @core_ws.Extension for PerMessageDeflate with fn encode(self, bytes) {
  if self.encode_reset {
    self.encoder.reset()
  }
  // A repeated empty sync flush emits nothing. An empty stored-block header
  // is the RFC 7692 representation, independent of the previous dictionary.
  if bytes.is_empty() {
    return (b"\x00", true)
  }
  let output : Array[Byte] = []
  let scratch = FixedArray::make(8192, b'\x00')
  let mut at = 0
  for ;; {
    let status : @codec_bytes.Status = self.encoder.step_into(
      bytes[at:],
      scratch,
      action=Flush,
    )
    at += self.encoder.last_consumed()
    output.append(scratch[:self.encoder.last_produced()])
    if status is NeedMoreInput {
      break
    }
  }
  (Bytes::from_array(output[:output.length() - 4]), true)
}

///|
fn history_after(history : Bytes, bytes : Bytes) -> Bytes {
  if bytes.is_empty() {
    history
  } else if bytes.length() >= 32768 {
    bytes[bytes.length() - 32768:].to_owned()
  } else {
    history[(history.length() + bytes.length() - 32768).max(0):].to_owned() +
    bytes
  }
}

///|
// RFC 7692 permits BFINAL within a message, so a byte bound alone admits
// hundreds of thousands of empty members. Eight restarts allow concatenation
// while limiting resets and at most nine 32 KiB dictionary loads per message.
// One Decoder owns all window/table storage for the message. Exceeding this resource
// limit is Close 1009, rather than declaring otherwise valid framing invalid.
let max_deflate_final_members : Int32 = 8

///|
impl @core_ws.Extension for PerMessageDeflate with fn decode(
  self,
  bytes,
  rsv1~,
  max_bytes~,
) {
  if max_bytes < 0 || (!rsv1 && bytes.length() > max_bytes) {
    raise @core_ws.WsError(
      kind=TooLarge(limit=max_bytes),
      detail="inflated message limit",
    )
  }
  if !rsv1 {
    return bytes
  }
  if bytes.is_empty() {
    raise @core_ws.WsError(
      kind=Protocol,
      detail="missing permessage-deflate block header",
    )
  }
  // Decode only received bytes as data. A synthetic final block could satisfy
  // a truncated stored block and fabricate message bytes, so only the RFC
  // sync-flush tail is supplied separately and must produce no output.
  let output : Array[Byte] = []
  let mut history = if self.decode_reset { b"" } else { self.history }
  let decoder = @deflate.Decoder(until=EndOfMember)
  let scratch = FixedArray::make(8192, b'\x00')
  // A bare reset keeps the last dictionary given; no takeover needs b"".
  decoder.reset(dictionary=history)
  let mut member_start = 0
  let mut final_members = 0
  let tail = b"\x00\x00\xff\xff"
  for phase in 0..<2 {
    let mut input = if phase == 0 { bytes[:] } else { tail[:] }
    for ;; {
      let remaining = max_bytes - output.length()
      // One byte probes overflow without ever accumulating an oversized message.
      // The tail also gets one output byte so stored-block data is detectable.
      let capacity = if phase == 1 {
        1
      } else if remaining < 8192 {
        remaining + 1
      } else {
        8192
      }
      let status = try {
        if capacity == scratch.length() {
          decoder.step_into(input, scratch, end=false)
        } else {
          decoder.step(input, scratch.mut_view(end=capacity), end=false)
        }
      } catch {
        _ => {
          if phase == 0 && decoder.last_produced() > remaining {
            raise @core_ws.WsError(
              kind=TooLarge(limit=max_bytes),
              detail="inflated message limit",
            )
          }
          raise @core_ws.WsError(
            kind=Protocol,
            detail="invalid permessage-deflate payload",
          )
        }
      }
      let produced = decoder.last_produced()
      if phase == 1 && produced != 0 {
        raise @core_ws.WsError(
          kind=Protocol,
          detail="permessage-deflate tail produced data",
        )
      }
      if produced > remaining {
        raise @core_ws.WsError(
          kind=TooLarge(limit=max_bytes),
          detail="inflated message limit",
        )
      }
      // Save the remainder before reset, which clears last_consumed().
      input = input[decoder.last_consumed():]
      output.append(scratch[:produced])
      if status is Done {
        if final_members >= max_deflate_final_members {
          raise @core_ws.WsError(
            kind=TooLarge(limit=max_deflate_final_members),
            detail="permessage-deflate final member work limit",
          )
        }
        final_members += 1
        if output.length() > member_start {
          history = history_after(
            history,
            Bytes::from_array(output[member_start:]),
          )
        }
        member_start = output.length()
        // BFINAL starts another stream within this message with the same
        // window, even when context takeover between messages is disabled.
        decoder.reset(dictionary=history)
      } else if status is NeedMoreInput {
        if !input.is_empty() {
          raise @core_ws.WsError(
            kind=Protocol,
            detail="unconsumed permessage-deflate input",
          )
        }
        break
      }
    }
  }
  if !decoder.at_block_boundary() {
    raise @core_ws.WsError(
      kind=Protocol,
      detail="permessage-deflate tail is not framing",
    )
  }
  let decoded = Bytes::from_array(output)
  if !self.decode_reset {
    self.history = history_after(
      history,
      Bytes::from_array(output[member_start:]),
    )
  }
  decoded
}
