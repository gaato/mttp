// A fuzzer's input read as a program: bytes taken one at a time, zero past
// the end, so that every input is a whole program.

///|
priv struct Input {
  data : Bytes
  mut at : Int32
}

///|
fn Input::new(data : Bytes) -> Input {
  { data, at: 0, }
}

///|
fn Input::done(self : Input) -> Bool {
  self.at >= self.data.length()
}

///|
fn Input::byte(self : Input) -> Int32 {
  if self.done() {
    return 0
  }
  self.at += 1
  self.data[self.at - 1].to_int()
}

///|
/// Up to `n` bytes, fewer near the end.
fn Input::bytes(self : Input, n : Int32) -> Bytes {
  let end = (self.at + n).min(self.data.length())
  let out = self.data[self.at:end].to_owned()
  self.at = end
  out
}

///|
/// The rest of the input.
fn Input::rest(self : Input) -> Bytes {
  self.bytes(self.data.length())
}

///|
/// Bytes as a field string, one character per octet (the engines' fields
/// are octets, ISO-8859-1).
fn octets(bytes : Bytes) -> String {
  let out = StringBuilder()
  for b in bytes {
    out.write_char(b.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// A field name: lower-case letters and digits, so that most are valid,
/// or, when the input says so, any octets.
fn Input::name(self : Input) -> String {
  let len = self.byte() % 12 + 1
  let raw = self.byte() % 16 == 0
  let bytes = self.bytes(len)
  if raw {
    return octets(bytes)
  }
  let out = StringBuilder()
  for b in bytes {
    let i = b.to_int() % 36
    out.write_char(
      if i < 26 {
        ('a'.to_int() + i).unsafe_to_char()
      } else {
        ('0'.to_int() + i - 26).unsafe_to_char()
      },
    )
  }
  if out.to_string().is_empty() {
    "x"
  } else {
    out.to_string()
  }
}

///|
/// A field value: any octets.
fn Input::value(self : Input) -> String {
  octets(self.bytes(self.byte() % 40))
}

///|
/// Up to three fields after `base`.
fn Input::fields(
  self : Input,
  base : Array[(String, String)],
) -> Array[(String, String)] {
  let fields = base.copy()
  for _ in 0..<(self.byte() % 4) {
    fields.push((self.name(), self.value()))
  }
  fields
}

///|
/// What a peer received of one stream's body, checked against what was
/// pushed: always a prefix of it.
fn check_prefix(what : String, received : Bytes, pushed : Bytes) -> Unit {
  if received.length() > pushed.length() ||
    received != pushed[:received.length()].to_owned() {
    abort("\{what}: the bytes received are not the bytes pushed")
  }
}

///|
/// The fields as their sender puts them on the wire: nghttp2 and nghttp3
/// write field names in lower case (ASCII), as HTTP/2 and HTTP/3 have them.
fn as_sent(fields : Array[(String, String)]) -> Array[(String, String)] {
  fields.map(field => {
    let name = StringBuilder()
    for c in field.0 {
      name.write_char(
        if c is ('A'..<='Z') {
          (c.to_int() + 32).unsafe_to_char()
        } else {
          c
        },
      )
    }
    (name.to_string(), field.1)
  })
}

///|
/// The message of a head that changed on the way, with both field lists.
fn changed(
  what : String,
  got : Array[(String, String)],
  sent : Array[(String, String)],
) -> String {
  "the \{what}'s fields changed on the way: sent \{@debug.to_string(sent)}, got \{@debug.to_string(got)}"
}
