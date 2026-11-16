// The WebSocket target: frame.Parser, run whole, cut at a fuzzer-chosen
// place and fed one byte at a time, with the invariants of ws/frame's
// corpus and property tests: no panic, `next` always makes progress, and the
// heads, payloads, ends and failure kind do not depend on the cut.

///|
#derive(Eq, Debug)
struct Trace {
  heads : Array[@frame.FrameHead]
  payloads : Array[Bytes]
  ends : Int32
  failure : @frame.FrameErrorKind?
}

///|
fn read_frames(
  pieces : Array[Bytes],
  role : @frame.Role,
  limit : Int32,
  allow_rsv1 : Bool,
) -> Trace {
  let parser = @frame.Parser::new(role~, max_frame_bytes=limit, allow_rsv1~)
  let heads = []
  let payloads : Array[Buffer] = []
  let mut ends = 0
  let mut budget = pieces.fold(init=3, (n, p) => n + 3 * p.length()) +
    pieces.length()
  for piece in pieces {
    parser.feed(piece)
    for ;; {
      budget -= 1
      if budget < 0 {
        abort("parser next made no progress")
      }
      let event = parser.next() catch {
        @frame.FrameError(kind~, ..) =>
          return {
            heads,
            payloads: payloads.map(buffer => buffer.to_bytes()),
            ends,
            failure: Some(kind),
          }
      }
      match event {
        None => break
        Some(Head(head)) => {
          heads.push(head)
          payloads.push(Buffer())
        }
        Some(Payload(bytes)) => {
          if bytes.is_empty() || payloads.is_empty() {
            abort("empty or headless payload")
          }
          payloads[payloads.length() - 1].write_bytes(bytes)
        }
        Some(End) => ends += 1
      }
    }
  }
  {
    heads,
    payloads: payloads.map(buffer => buffer.to_bytes()),
    ends,
    failure: None,
  }
}

///|
/// Input: [mode, cut_hi, cut_lo, ..wire]. mode bit 0: server role; bit 1:
/// allow rsv1; bits 2-3: frame limit.
pub fn fuzz_ws(data : Bytes) -> Int32 {
  if data.length() < 3 {
    return 0
  }
  let mode = data[0].to_int()
  let wire = data[3:].to_owned()
  let cut = ((data[1].to_int() << 8) | data[2].to_int()) % (wire.length() + 1)
  let role : @frame.Role = if (mode & 1) != 0 { Server } else { Client }
  let allow_rsv1 = (mode & 2) != 0
  let limit = [0, 125, 65536, 2147483647][(mode >> 2) & 3]
  let whole = read_frames([wire], role, limit, allow_rsv1)
  let split = read_frames(
    [wire[:cut].to_owned(), wire[cut:].to_owned()],
    role,
    limit,
    allow_rsv1,
  )
  if split != whole {
    abort("split at \{cut} differs: \{Repr(whole)} vs \{Repr(split)}")
  }
  if wire.length() <= 2048 {
    let bytes = read_frames(
      Array::makei(wire.length(), i => wire[i:i + 1].to_owned()),
      role,
      limit,
      allow_rsv1,
    )
    if bytes != whole {
      abort("byte by byte differs: \{Repr(whole)} vs \{Repr(bytes)}")
    }
  }
  if whole.failure is Some(_) {
    2
  } else {
    1
  }
}
