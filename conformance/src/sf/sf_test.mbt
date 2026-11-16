// httpwg's structured-field-tests (see NOTICE) against gaato/mttp_core/sf:
// each parsing case is parsed as its header_type says, compared with its
// expected value, and serialized back to its canonical form (its raw lines
// when it has none); each serialisation case is serialized, or must fail.
// `can_fail` cases may fail; when they parse, they must give the expected
// value. The JSON form is the suite's: an Item is [bare, params], an Inner
// List [[items], params], a Dictionary [[key, member], ...], and tokens,
// byte sequences (in base32), dates and display strings are objects with
// `__type`.

///|
priv suberror Bad {
  Bad(String)
}

///|
fn base32(text : String) -> Bytes raise Bad {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  let out = Buffer()
  let mut acc = 0
  let mut bits = 0
  for c in text {
    if c == '=' {
      break
    }
    guard alphabet.find(c.to_string()) is Some(v) else {
      raise Bad("base32 \{text}")
    }
    acc = ((acc << 5) | v) & 0xFFFF
    bits += 5
    if bits >= 8 {
      bits -= 8
      out.write_byte(((acc >> bits) & 0xFF).to_byte())
    }
  }
  out.to_bytes()
}

///|
/// A decimal number's value in thousandths, rounded to three fractional
/// digits with ties to even, with no range check: the serializer, not this,
/// must refuse what is too large.
fn milli_of(text : String) -> Int64 raise Bad {
  let negative = text.has_prefix("-")
  let digits = if negative { text[1:].to_owned() } else { text }
  guard digits.split(".").map(part => part.to_owned()).collect()
    is [whole, frac] else {
    raise Bad("decimal \{text}")
  }
  let parse = (s : String) => {
    @string.parse_int64(s) catch {
      _ => raise Bad("decimal \{text}")
    }
  }
  let padded = frac + "000"
  let mut milli = parse(whole) * 1000L + parse(padded[:3].to_owned())
  let rest = padded[3:].to_owned()
  let half = rest.length() > 0 && rest[0] == '5'
  let above = (rest.length() > 0 && rest[0] > '5') ||
    (half && rest[1:].iter().any(c => c != '0'))
  if above || (half && !above && milli % 2L == 1L) {
    milli += 1L
  }
  if negative {
    -milli
  } else {
    milli
  }
}

///|
fn bare_of(json : Json) -> @sfv.BareItem raise Bad {
  match json {
    Number(n, repr~) => {
      let text = repr.unwrap_or(n.to_string())
      if text.contains(".") {
        Decimal(milli_of(text))
      } else {
        Integer(@string.parse_int64(text) catch { _ => raise Bad(text) })
      }
    }
    String(s) => String(s)
    True => Boolean(true)
    False => Boolean(false)
    Object(o) =>
      match (o.get("__type"), o.get("value")) {
        (Some(String("token")), Some(String(t))) => Token(t)
        (Some(String("binary")), Some(String(b))) => Bytes(base32(b))
        (Some(String("displaystring")), Some(String(s))) => DisplayString(s)
        (Some(String("date")), Some(Number(_, repr~))) =>
          Date(
            @string.parse_int64(repr.unwrap_or("x")) catch {
              _ => raise Bad("date")
            },
          )
        _ => raise Bad("bare \{json.stringify()}")
      }
    _ => raise Bad("bare \{json.stringify()}")
  }
}

///|
fn params_of(json : Json) -> @sfv.Parameters raise Bad {
  guard json is Array(pairs) else { raise Bad("params") }
  pairs.map(pair => {
    guard pair is [String(key), value] else { raise Bad("param") }
    (key, bare_of(value))
  })
}

///|
fn item_of(json : Json) -> @sfv.Item raise Bad {
  guard json is [bare, params] else { raise Bad("item") }
  { value: bare_of(bare), params: params_of(params), }
}

///|
fn member_of(json : Json) -> @sfv.Member raise Bad {
  match json {
    [Array(items), params] => InnerList(items.map(item_of), params_of(params))
    _ => Item(item_of(json))
  }
}

///|
fn list_of(json : Json) -> Array[@sfv.Member] raise Bad {
  guard json is Array(members) else { raise Bad("list") }
  members.map(member_of)
}

///|
fn dictionary_of(json : Json) -> @sfv.Dictionary raise Bad {
  guard json is Array(pairs) else { raise Bad("dictionary") }
  pairs.map(pair => {
    guard pair is [String(key), value] else { raise Bad("entry") }
    (key, member_of(value))
  })
}

///|
fn strings(json : Json?) -> Array[String]? raise Bad {
  match json {
    None => None
    Some(Array(lines)) =>
      Some(
        lines.map(line => {
          guard line is String(s) else { raise Bad("line") }
          s
        }),
      )
    _ => raise Bad("lines")
  }
}

///|
/// The field parsed as `kind`, and the parse serialized back.
fn parse_and_serialize(
  kind : String,
  raw : Array[String],
  expected : Json?,
) -> (Bool, String?) raise Bad {
  match kind {
    "item" =>
      match @sfv.parse_item(raw) {
        None => (false, None)
        Some(item) => {
          if expected is Some(want) && item_of(want) != item {
            raise Bad("parsed \{@debug.to_string(item)}")
          }
          (true, @sfv.serialize_item(item))
        }
      }
    "list" =>
      match @sfv.parse_list(raw) {
        None => (false, None)
        Some(list) => {
          if expected is Some(want) && list_of(want) != list {
            raise Bad("parsed \{@debug.to_string(list)}")
          }
          (true, @sfv.serialize_list(list))
        }
      }
    "dictionary" =>
      match @sfv.parse_dictionary(raw) {
        None => (false, None)
        Some(dict) => {
          if expected is Some(want) && dictionary_of(want) != dict {
            raise Bad("parsed \{@debug.to_string(dict)}")
          }
          (true, @sfv.serialize_dictionary(dict))
        }
      }
    _ => raise Bad("header_type \{kind}")
  }
}

///|
/// Serializes the case's expected value; None when it cannot be written or
/// the suite's value is outside what `@sf` holds.
fn serialize_expected(kind : String, expected : Json) -> String? {
  try {
    match kind {
      "item" => @sfv.serialize_item(item_of(expected))
      "list" => @sfv.serialize_list(list_of(expected))
      "dictionary" => @sfv.serialize_dictionary(dictionary_of(expected))
      _ => None
    }
  } catch {
    _ => None
  }
}

///|
/// The outcome of one case, or the reason it failed.
fn run_case(fields : Map[String, Json]) -> String? raise Bad {
  guard fields.get("header_type") is Some(String(kind)) else {
    raise Bad("no header_type")
  }
  let must_fail = fields.get("must_fail") is Some(True)
  let can_fail = fields.get("can_fail") is Some(True)
  let canonical = strings(fields.get("canonical"))
  guard strings(fields.get("raw")) is Some(raw) else {
    // A serialisation case.
    let written = match fields.get("expected") {
      Some(expected) => serialize_expected(kind, expected)
      None => None
    }
    if must_fail {
      return if written is Some(w) { Some("serialized as \{w}") } else { None }
    }
    let want = canonical.unwrap_or([]).join(", ")
    return if written == Some(want) {
      None
    } else {
      Some("serialized as \{written.unwrap_or("nothing")}, not \{want}")
    }
  }
  let (parsed, written) = parse_and_serialize(
    kind,
    raw,
    if must_fail {
      None
    } else {
      fields.get("expected")
    },
  ) catch {
    Bad(why) => return Some(why)
  }
  if must_fail {
    return if parsed { Some("parsed") } else { None }
  }
  if !parsed {
    return if can_fail { None } else { Some("failed to parse") }
  }
  let want = canonical.unwrap_or(raw).join(", ")
  if written == Some(want) {
    None
  } else {
    Some("serialized as \{written.unwrap_or("nothing")}, not \{want}")
  }
}

///|
test "structured-field-tests: every case parses, fails or serializes as the suite says" {
  guard @json.parse(structured_field_tests, preserve_number_repr=true)
    is Array(rows) else {
    fail("bad vectors")
  }
  let failures = []
  let mut parse_cases = 0
  let mut serialise_cases = 0
  for row in rows {
    guard row is Object(fields) else { fail("bad row") }
    if fields.get("raw") is Some(_) {
      parse_cases += 1
    } else {
      serialise_cases += 1
    }
    let name = match (fields.get("file"), fields.get("name")) {
      (Some(String(f)), Some(String(n))) => "\{f}: \{n}"
      _ => "?"
    }
    if run_case(fields) is Some(why) {
      failures.push("\{name}: \{why}")
    }
  }
  if !failures.is_empty() {
    fail(
      "\{failures.length()} failed:\n\{failures[:failures.length().min(40)].join("\n")}",
    )
  }
  assert_eq((parse_cases, serialise_cases), (1607, 553))
}
