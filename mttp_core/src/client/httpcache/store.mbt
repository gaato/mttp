///|
priv struct Entry {
  key : CacheKey
  stored : Stored
  bytes : Int64
}

///|
/// In-memory LRU, bounded across all keys and variants. The byte budget
/// counts bodies and UTF-16 URL, credential and header storage (two bytes
/// per code unit), so empty bodies cannot bypass the byte bound.
pub struct MemoryStore {
  priv entries : Array[Entry]
  priv max_entries : Int32
  priv max_bytes : Int64
  priv mut bytes : Int64
}

///|
pub fn MemoryStore::new(
  max_entries~ : Int32 = 1024,
  max_bytes~ : Int64 = 16777216L,
) -> MemoryStore {
  {
    entries: [],
    max_entries: max_entries.max(0),
    max_bytes: max_bytes.max(0L),
    bytes: 0L,
  }
}

///|
pub extend MemoryStore with CacheStore::{lookup, insert, remove}

///|
fn stored_size(key : CacheKey, stored : Stored) -> Int64 {
  let mut bytes = stored.body.length().to_int64() +
    key.url.length().to_int64() * 2L
  if key.credential is Some(c) {
    bytes += c.length().to_int64() * 2L
  }
  for headers in [stored.vary_headers, stored.head.headers] {
    for (name, value) in headers.iter() {
      bytes += (name.length().to_int64() + value.length().to_int64()) * 2L
    }
  }
  bytes
}

///|
pub impl CacheStore for MemoryStore with fn lookup(self, key) {
  let found = []
  let keep = []
  for entry in self.entries {
    if entry.key == key {
      found.push(entry)
    } else {
      keep.push(entry)
    }
  }
  self.entries.clear()
  self.entries.append(keep)
  self.entries.append(found)
  found.map(e => e.stored)
}

///|
pub impl CacheStore for MemoryStore with fn insert(self, key, stored) {
  let bytes = stored_size(key, stored)
  let keep = []
  for entry in self.entries {
    if entry.key == key && entry.stored.vary_headers == stored.vary_headers {
      self.bytes -= entry.bytes
    } else {
      keep.push(entry)
    }
  }
  self.entries.clear()
  self.entries.append(keep)
  if self.max_entries == 0 || bytes > self.max_bytes {
    return
  }
  while self.entries.length() >= self.max_entries ||
        self.bytes > self.max_bytes - bytes {
    let entry = self.entries.remove(0)
    self.bytes -= entry.bytes
  }
  self.entries.push({ key, stored, bytes, })
  self.bytes += bytes
}

///|
pub impl CacheStore for MemoryStore with fn remove(self, key) {
  let keep = []
  for entry in self.entries {
    if entry.key.url == key.url {
      self.bytes -= entry.bytes
    } else {
      keep.push(entry)
    }
  }
  self.entries.clear()
  self.entries.append(keep)
}
