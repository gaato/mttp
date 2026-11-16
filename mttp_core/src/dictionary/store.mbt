// A client's store of compression dictionaries (RFC 9842 section 2):
// which responses become dictionaries, and which one a request offers.

///|
/// The most dictionaries a store keeps by default.
pub const DEFAULT_MAX_ENTRIES : Int32 = 64

///|
/// The largest dictionary a store keeps by default, in bytes.
pub const DEFAULT_MAX_DICTIONARY_BYTES : Int32 = 4 * 1024 * 1024

///|
/// The most dictionary bytes a store keeps by default.
pub const DEFAULT_MAX_TOTAL_BYTES : Int32 = 32 * 1024 * 1024

///|
/// A stored dictionary.
pub struct Dictionary {
  /// The URL it was fetched from, without its fragment.
  url : @mttp_core.Url
  /// Its Use-As-Dictionary.
  directive : UseAsDictionary
  /// Its bytes.
  content : Bytes
  /// SHA-256 of `content`.
  hash : Bytes
  /// The partition it was stored in.
  partition : String
  priv pattern : @urlpattern.UrlPattern
  priv headers : @mttp_core.Headers
  priv request_time_ms : Int64
  priv response_time_ms : Int64
  // Stores happen in order; a later store is more recent.
  priv sequence : Int64
}

///|
/// The Available-Dictionary field value for this dictionary: its hash as a
/// Structured Fields Byte Sequence (section 2.2).
pub fn Dictionary::available_dictionary(self : Dictionary) -> String {
  @sf.serialize_bare_item(Bytes(self.hash)).unwrap_or("")
}

///|
/// The Dictionary-ID field value, when the server gave the dictionary an
/// id (section 2.3).
pub fn Dictionary::dictionary_id(self : Dictionary) -> String? {
  guard self.directive.id != "" else { return None }
  @sf.serialize_bare_item(String(self.directive.id))
}

///|
/// The dictionary's freshness at `now_ms`, as a private cache sees it.
fn Dictionary::freshness(self : Dictionary, now_ms : Int64) -> @cache.Freshness {
  @cache.Freshness::of(
    self.headers,
    shared=false,
    request_time_ms=self.request_time_ms,
    response_time_ms=self.response_time_ms,
    now_ms~,
  )
}

///|
/// Whether section 2.2.1 lets the dictionary be used at `now_ms`: reusable
/// as it is (fresh and not `no-cache`), or stale within its
/// stale-while-revalidate window (RFC 5861).
fn Dictionary::usable(self : Dictionary, now_ms : Int64) -> Bool {
  let f = self.freshness(now_ms)
  f.reusable() || f.may_serve_while_revalidating()
}

///|
/// A client's dictionaries, partitioned as its cookies are (section 10):
/// a dictionary stored in one partition is never offered in another.
pub struct DictionaryStore {
  priv sha256 : (BytesView) -> Bytes
  priv clock : &@rt.Clock
  priv max_entries : Int32
  priv max_dictionary_bytes : Int32
  priv max_total_bytes : Int32
  priv entries : Array[Dictionary]
  // Int64, so caps up to Int's range cannot wrap the sum.
  priv mut total_bytes : Int64
  priv mut sequence : Int64
}

///|
/// An empty store. `sha256` hashes a dictionary's bytes (32 bytes out);
/// mttp_core carries no SHA-256, so the caller passes one, such as
/// `moonbitlang/x/crypto`'s. Caps below 0 count as 0.
pub fn DictionaryStore::new(
  sha256~ : (BytesView) -> Bytes,
  clock~ : &@rt.Clock,
  max_entries~ : Int32 = DEFAULT_MAX_ENTRIES,
  max_dictionary_bytes~ : Int32 = DEFAULT_MAX_DICTIONARY_BYTES,
  max_total_bytes~ : Int32 = DEFAULT_MAX_TOTAL_BYTES,
) -> DictionaryStore {
  {
    sha256,
    clock,
    max_entries: max_entries.max(0),
    max_dictionary_bytes: max_dictionary_bytes.max(0),
    max_total_bytes: max_total_bytes.max(0),
    entries: [],
    total_bytes: 0L,
    sequence: 0L,
  }
}

///|
/// Whether dictionaries may be stored from and offered to `url`: https, or
/// http to a loopback host, where the bytes cannot be read or changed on the
/// way: `localhost` and names under it (with or without the root dot), an
/// IPv4 address in 127.0.0.0/8, or ::1, as Secure Contexts counts them
/// potentially trustworthy.
pub fn is_trustworthy(url : @mttp_core.Url) -> Bool {
  guard url.scheme is Some(scheme) && url.host is Some(host) else {
    return false
  }
  if scheme == "https" {
    return true
  }
  guard scheme == "http" else { return false }
  let name = host.to_lower()
  let name = if name.has_suffix(".") {
    name[:name.length() - 1].to_owned()
  } else {
    name
  }
  name == "localhost" ||
  name.has_suffix(".localhost") ||
  name == "::1" ||
  is_loopback_ipv4(name)
}

///|
/// Whether `host` is four decimal octets, the first 127.
fn is_loopback_ipv4(host : String) -> Bool {
  let parts = host.split(".").collect()
  guard parts.length() == 4 else { return false }
  for i, part in parts {
    guard part.length() >= 1 &&
      part.length() <= 3 &&
      part.iter().all(c => c.is_ascii_digit()) else {
      return false
    }
    let mut v = 0
    for c in part {
      v = v * 10 + (c.to_int() - '0'.to_int())
    }
    guard v <= 255 && (i != 0 || v == 127) else { return false }
  }
  true
}

///|
fn DictionaryStore::remove_at(self : DictionaryStore, index : Int32) -> Unit {
  let d = self.entries.remove(index)
  self.total_bytes -= d.content.length().to_int64()
}

///|
/// Drops the dictionaries section 2.2.1 no longer lets anyone use.
fn DictionaryStore::drop_unusable(
  self : DictionaryStore,
  now_ms : Int64,
) -> Unit {
  let mut i = 0
  while i < self.entries.length() {
    if self.entries[i].usable(now_ms) {
      i += 1
    } else {
      self.remove_at(i)
    }
  }
}

///|
/// Offers a response to the store: it becomes a dictionary when its
/// request went to a trustworthy URL, it has a valid Use-As-Dictionary
/// whose `match` is a URL pattern without regular expressions (section
/// 2.1.1), it may be stored (not `no-store`), it is fresh, and it fits
/// the caps. `body` must be the whole, decoded body: offer only a
/// response that ended cleanly. A dictionary from the same partition and
/// URL is replaced. The oldest dictionaries make room past the caps.
/// Returns whether it was stored.
pub fn DictionaryStore::offer(
  self : DictionaryStore,
  url : @mttp_core.Url,
  headers : @mttp_core.Headers,
  body : Bytes,
  request_time_ms~ : Int64,
  partition~ : String = "",
) -> Bool {
  guard is_trustworthy(url) else { return false }
  guard UseAsDictionary::parse(headers.get_all("use-as-dictionary"))
    is Some(directive) else {
    return false
  }
  let url = url.without_fragment()
  let pattern = @urlpattern.UrlPattern::parse(directive.match_, base=url) catch {
    _ => return false
  }
  guard body.length() <= self.max_dictionary_bytes &&
    body.length() <= self.max_total_bytes &&
    self.max_entries > 0 else {
    return false
  }
  let now_ms = self.clock.now_unix_ms()
  self.sequence += 1L
  let d : Dictionary = {
    url,
    directive,
    content: body,
    hash: (self.sha256)(body),
    partition,
    pattern,
    headers,
    request_time_ms,
    response_time_ms: now_ms,
    sequence: self.sequence,
  }
  let f = d.freshness(now_ms)
  guard f.storable() && (f.reusable() || f.may_serve_while_revalidating()) else {
    return false
  }
  // A new response for the same URL replaces the stored one.
  match self.entries.search_by(e => e.partition == partition && e.url == url) {
    Some(i) => self.remove_at(i)
    None => ()
  }
  self.drop_unusable(now_ms)
  while self.entries.length() >= self.max_entries ||
        self.total_bytes + body.length().to_int64() >
        self.max_total_bytes.to_int64() {
    // Entries are kept in the order they were stored.
    self.remove_at(0)
  }
  self.entries.push(d)
  self.total_bytes += body.length().to_int64()
  true
}

///|
/// The dictionary a request to `url` should offer, by section 2.2.3: of the
/// usable dictionaries of `partition`, from `url`'s origin, whose pattern
/// matches `url` and whose `match-dest` includes `dest` (or is empty), one
/// that names `dest` comes first, then the longest `match`, then the most
/// recently stored. None for an untrustworthy URL. `dest` is the Fetch
/// request destination; without one, every `match-dest` matches, as for a
/// client that does not support destinations.
pub fn DictionaryStore::select(
  self : DictionaryStore,
  url : @mttp_core.Url,
  dest? : String,
  partition~ : String = "",
) -> Dictionary? {
  guard is_trustworthy(url) else { return None }
  let now_ms = self.clock.now_unix_ms()
  self.drop_unusable(now_ms)
  let mut best : Dictionary? = None
  let mut best_rank = (false, -1, -1L)
  for d in self.entries {
    guard d.partition == partition && d.url.same_origin(url) else { continue }
    let names_dest = match dest {
      Some(want) if !d.directive.match_dest.is_empty() => {
        guard d.directive.match_dest.contains(want) else { continue }
        true
      }
      _ => false
    }
    guard d.pattern.matches(url) else { continue }
    let rank = (names_dest, d.directive.match_.length(), d.sequence)
    if best is None || compare_rank(rank, best_rank) > 0 {
      best = Some(d)
      best_rank = rank
    }
  }
  best
}

///|
fn compare_rank(a : (Bool, Int32, Int64), b : (Bool, Int32, Int64)) -> Int32 {
  if a.0 != b.0 {
    return if a.0 { 1 } else { -1 }
  }
  if a.1 != b.1 {
    return a.1 - b.1
  }
  a.2.compare(b.2)
}

///|
/// The stored dictionary of `partition` whose SHA-256 is `hash`, for
/// decoding a response that names it.
pub fn DictionaryStore::find(
  self : DictionaryStore,
  hash : BytesView,
  partition~ : String = "",
) -> Dictionary? {
  for d in self.entries {
    if d.partition == partition && d.hash[:] == hash {
      return Some(d)
    }
  }
  None
}

///|
/// Forgets the dictionaries of `partition`, or all of them; section 10 has a
/// client clear them whenever it clears cookies.
pub fn DictionaryStore::clear(
  self : DictionaryStore,
  partition? : String,
) -> Unit {
  match partition {
    None => {
      self.entries.clear()
      self.total_bytes = 0L
    }
    Some(p) => {
      let mut i = 0
      while i < self.entries.length() {
        if self.entries[i].partition == p {
          self.remove_at(i)
        } else {
          i += 1
        }
      }
    }
  }
}

///|
/// The store's clock, read now: the time a client sends a request at, for
/// `offer`'s `request_time_ms`.
pub fn DictionaryStore::now_unix_ms(self : DictionaryStore) -> Int64 {
  self.clock.now_unix_ms()
}

///|
/// The largest dictionary the store keeps, in bytes: a client need not
/// collect more of a body to offer it.
pub fn DictionaryStore::max_dictionary_bytes(self : DictionaryStore) -> Int32 {
  self.max_dictionary_bytes.min(self.max_total_bytes)
}

///|
/// How many dictionaries are stored, and their bytes.
pub fn DictionaryStore::size(self : DictionaryStore) -> (Int32, Int64) {
  (self.entries.length(), self.total_bytes)
}
