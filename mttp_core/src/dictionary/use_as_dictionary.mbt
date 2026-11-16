// The Use-As-Dictionary response header (RFC 9842 section 2.1).

///|
/// The largest Use-As-Dictionary field read, in bytes over all its lines.
pub const MAX_HEADER_BYTES : Int32 = 8192

///|
/// The longest `match` kept, in characters.
pub const MAX_MATCH_LENGTH : Int32 = 1024

///|
/// The longest `id`, in characters, as RFC 9842 section 2.1.3 allows.
pub const MAX_ID_LENGTH : Int32 = 1024

///|
/// What a Use-As-Dictionary field says.
#derive(Eq, Debug)
pub(all) struct UseAsDictionary {
  /// The URL pattern requests must match.
  match_ : String
  /// The request destinations it is for; empty matches them all.
  match_dest : Array[String]
  /// The server's identifier, echoed in Dictionary-ID; empty for none.
  id : String
}

///|
/// Compares two directives.
pub extend UseAsDictionary with Eq::{equal, not_equal}

///|
/// Debug representation of a directive.
pub extend UseAsDictionary with @debug.Debug::{to_repr}

///|
/// Reads the lines of a Use-As-Dictionary field. None when the field is not
/// a Structured Fields Dictionary, has no `match` String, or its parts have
/// the wrong types, are too long, or name a `type` other than `raw`, which
/// section 2.1.4 forbids using.
pub fn UseAsDictionary::parse(lines : ArrayView[String]) -> UseAsDictionary? {
  let mut size = 0
  for line in lines {
    size += line.length()
  }
  guard size <= MAX_HEADER_BYTES else { return None }
  guard @sf.parse_dictionary(lines.to_owned()) is Some(dict) else {
    return None
  }
  let mut match_ = None
  let mut match_dest = []
  let mut id = ""
  for entry in dict {
    match entry {
      ("match", Item({ value: String(m), .. })) => match_ = Some(m)
      ("match", _) => return None
      ("match-dest", InnerList(items, _)) => {
        let dests = []
        for item in items {
          guard item.value is String(d) else { return None }
          dests.push(d)
        }
        match_dest = dests
      }
      ("match-dest", _) => return None
      ("id", Item({ value: String(s), .. })) => id = s
      ("id", _) => return None
      ("type", Item({ value: Token("raw"), .. })) => ()
      ("type", _) => return None
      _ => ()
    }
  }
  guard match_ is Some(m) && m.length() <= MAX_MATCH_LENGTH else { return None }
  guard id.length() <= MAX_ID_LENGTH else { return None }
  Some({ match_: m, match_dest, id, })
}

///|
/// The field value that says `self`, for a server to send; None when a
/// string in it is not printable ASCII, which a Structured Field cannot carry.
pub fn UseAsDictionary::to_header(self : UseAsDictionary) -> String? {
  // Longer than a client reads (section 2.1.3), it would be ignored.
  guard self.match_.length() <= MAX_MATCH_LENGTH &&
    self.id.length() <= MAX_ID_LENGTH else {
    return None
  }
  let dict : @sf.Dictionary = [
    ("match", Item(@sf.Item::of(String(self.match_)))),
  ]
  if !self.match_dest.is_empty() {
    dict.push(
      (
        "match-dest",
        InnerList(self.match_dest.map(d => @sf.Item::of(String(d))), []),
      ),
    )
  }
  if self.id != "" {
    dict.push(("id", Item(@sf.Item::of(String(self.id)))))
  }
  // A field longer than a client reads would be ignored.
  @sf.serialize_dictionary(dict).filter(v => v.length() <= MAX_HEADER_BYTES)
}
