// Parts and the pattern string parser (section 2.1, "Parsing pattern
// strings"), and turning a part list back into a pattern string (section
// 2.3).

///|
#derive(Eq)
priv enum PartType {
  FixedText
  Regexp
  SegmentWildcard
  FullWildcard
}

///|
#derive(Eq)
priv enum Modifier {
  None
  Optional
  ZeroOrMore
  OneOrMore
}

///|
priv struct Part {
  kind : PartType
  value : String
  modifier : Modifier
  name : String
  prefix : String
  suffix : String
}

///|
/// A component's options: the segment delimiter and the automatic prefix,
/// each one ASCII code point or none.
priv struct Options {
  delimiter : Char?
  prefix : Char?
}

///|
let default_options : Options = { delimiter: None, prefix: None, }

///|
let hostname_options : Options = { delimiter: Some('.'), prefix: None, }

///|
let pathname_options : Options = { delimiter: Some('/'), prefix: Some('/'), }

///|
/// The regular expression text a segment wildcard stands for, as the
/// standard writes it; a `regexp` token with exactly this text is a segment
/// wildcard, not a regular expression.
fn segment_wildcard_regexp(options : Options) -> String {
  match options.delimiter {
    None => "[^]+?"
    Some(d) => "[^\{escape_regexp(d.to_string())}]+?"
  }
}

///|
fn escape_regexp(input : String) -> String {
  let out = StringBuilder()
  for c in input {
    if ".+*?^${}()[]|/\\".contains_char(c) {
      out.write_char('\\')
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
/// Escapes the characters a pattern string gives meaning to.
fn escape_pattern(input : String) -> String {
  let out = StringBuilder()
  for c in input {
    if "+*?:{}()\\".contains_char(c) {
      out.write_char('\\')
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
priv struct Parser {
  tokens : Array[Token]
  encode : (String) -> String raise PatternError
  segment_wildcard : String
  parts : Array[Part]
  pending : StringBuilder
  mut index : Int32
  mut next_numeric_name : Int32
}

///|
fn Parser::try_consume(self : Parser, kind : TokenType) -> Token? {
  let token = self.tokens[self.index]
  guard token.kind == kind else { return None }
  self.index += 1
  Some(token)
}

///|
fn Parser::try_modifier(self : Parser) -> Token? {
  match self.try_consume(OtherModifier) {
    Some(t) => Some(t)
    None => self.try_consume(Asterisk)
  }
}

///|
fn Parser::try_regexp_or_wildcard(self : Parser, name : Token?) -> Token? {
  let token = self.try_consume(Regexp)
  if name is None && token is None {
    self.try_consume(Asterisk)
  } else {
    token
  }
}

///|
fn Parser::consume_text(self : Parser) -> String {
  let out = StringBuilder()
  for ;; {
    let token = match self.try_consume(Char) {
      Some(t) => Some(t)
      None => self.try_consume(EscapedChar)
    }
    guard token is Some(t) else { break }
    out.write_string(t.value)
  }
  out.to_string()
}

///|
fn Parser::flush_pending(self : Parser) -> Unit raise PatternError {
  let text = self.pending.to_string()
  guard text != "" else { return }
  self.pending.reset()
  self.parts.push({
    kind: FixedText,
    value: (self.encode)(text),
    modifier: None,
    name: "",
    prefix: "",
    suffix: "",
  })
}

///|
fn Parser::add_part(
  self : Parser,
  prefix : String,
  name_token : Token?,
  regexp_or_wildcard : Token?,
  suffix : String,
  modifier_token : Token?,
) -> Unit raise PatternError {
  let modifier : Modifier = match modifier_token {
    Some({ value: "?", .. }) => Optional
    Some({ value: "*", .. }) => ZeroOrMore
    Some({ value: "+", .. }) => OneOrMore
    _ => None
  }
  if name_token is None && regexp_or_wildcard is None && modifier == None {
    self.pending.write_string(prefix)
    return
  }
  self.flush_pending()
  if name_token is None && regexp_or_wildcard is None {
    guard prefix != "" else { return }
    self.parts.push({
      kind: FixedText,
      value: (self.encode)(prefix),
      modifier,
      name: "",
      prefix: "",
      suffix: "",
    })
    return
  }
  let regexp_value = match regexp_or_wildcard {
    None => self.segment_wildcard
    Some({ kind: Asterisk, .. }) => ".*"
    Some(t) => t.value
  }
  let (kind, value) : (PartType, String) = if regexp_value ==
    self.segment_wildcard {
    (SegmentWildcard, "")
  } else if regexp_value == ".*" {
    (FullWildcard, "")
  } else {
    (Regexp, regexp_value)
  }
  let name = match name_token {
    Some(t) => t.value
    None => {
      let n = self.next_numeric_name
      self.next_numeric_name += 1
      n.to_string()
    }
  }
  guard !self.parts.iter().any(p => p.name == name) else {
    raise Invalid("duplicate group name \{name}")
  }
  self.parts.push({
    kind,
    value,
    modifier,
    name,
    prefix: (self.encode)(prefix),
    suffix: (self.encode)(suffix),
  })
}

///|
/// Parses `input` as a pattern string into its parts, encoding fixed text
/// with `encode`.
fn parse_pattern(
  input : String,
  options : Options,
  encode : (String) -> String raise PatternError,
) -> Array[Part] raise PatternError {
  let parser : Parser = {
    tokens: tokenize(input.to_array(), false),
    encode,
    segment_wildcard: segment_wildcard_regexp(options),
    parts: [],
    pending: StringBuilder(),
    index: 0,
    next_numeric_name: 0,
  }
  while parser.index < parser.tokens.length() {
    let char_token = parser.try_consume(Char)
    let name_token = parser.try_consume(Name)
    let regexp_or_wildcard = parser.try_regexp_or_wildcard(name_token)
    if name_token is Some(_) || regexp_or_wildcard is Some(_) {
      let mut prefix = match char_token {
        Some(t) => t.value
        None => ""
      }
      let automatic = match options.prefix {
        Some(p) => prefix == p.to_string()
        None => false
      }
      if prefix != "" && !automatic {
        parser.pending.write_string(prefix)
        prefix = ""
      }
      parser.flush_pending()
      let modifier = parser.try_modifier()
      parser.add_part(prefix, name_token, regexp_or_wildcard, "", modifier)
      continue
    }
    let fixed = match char_token {
      Some(t) => Some(t)
      None => parser.try_consume(EscapedChar)
    }
    if fixed is Some(t) {
      parser.pending.write_string(t.value)
      continue
    }
    if parser.try_consume(Open) is Some(_) {
      let prefix = parser.consume_text()
      let name_token = parser.try_consume(Name)
      let regexp_or_wildcard = parser.try_regexp_or_wildcard(name_token)
      let suffix = parser.consume_text()
      guard parser.try_consume(Close) is Some(_) else {
        raise Invalid("a group without its }")
      }
      let modifier = parser.try_modifier()
      parser.add_part(prefix, name_token, regexp_or_wildcard, suffix, modifier)
      continue
    }
    parser.flush_pending()
    guard parser.try_consume(End) is Some(_) else {
      raise Invalid("unexpected \{parser.tokens[parser.index].value}")
    }
  }
  parser.parts
}

///|
fn starts_with_digit(name : String) -> Bool {
  name.get_char(0) is Some(c) && c.is_ascii_digit()
}

///|
fn modifier_text(m : Modifier) -> String {
  match m {
    ZeroOrMore => "*"
    Optional => "?"
    OneOrMore => "+"
    None => ""
  }
}

///|
/// The pattern string of `parts`, as section 2.3 generates it.
fn pattern_string(parts : Array[Part], options : Options) -> String {
  let out = StringBuilder()
  for index, part in parts {
    let previous = if index > 0 { Some(parts[index - 1]) } else { None }
    let next = if index + 1 < parts.length() {
      Some(parts[index + 1])
    } else {
      None
    }
    if part.kind == FixedText {
      if part.modifier == None {
        out.write_string(escape_pattern(part.value))
        continue
      }
      out.write_string("{\{escape_pattern(part.value)}}")
      out.write_string(modifier_text(part.modifier))
      continue
    }
    let custom_name = !starts_with_digit(part.name)
    let prefix_is_automatic = match options.prefix {
      Some(p) => part.prefix == p.to_string()
      None => false
    }
    let mut needs_grouping = part.suffix != "" ||
      (part.prefix != "" && !prefix_is_automatic)
    if !needs_grouping &&
      custom_name &&
      part.kind == SegmentWildcard &&
      part.modifier == None &&
      next is Some(n) &&
      n.prefix == "" &&
      n.suffix == "" {
      if n.kind == FixedText {
        needs_grouping = n.value.get_char(0) is Some(c) &&
          is_name_char(c, false)
      } else {
        needs_grouping = starts_with_digit(n.name)
      }
    }
    if !needs_grouping &&
      part.prefix == "" &&
      previous is Some(p) &&
      p.kind == FixedText &&
      options.prefix is Some(pc) &&
      p.value.to_array().last() == Some(pc) {
      needs_grouping = true
    }
    if needs_grouping {
      out.write_char('{')
    }
    out.write_string(escape_pattern(part.prefix))
    if custom_name {
      out.write_char(':')
      out.write_string(part.name)
    }
    match part.kind {
      Regexp => out.write_string("(\{part.value})")
      SegmentWildcard if !custom_name =>
        out.write_string("(\{segment_wildcard_regexp(options)})")
      FullWildcard =>
        if !custom_name &&
          (
            previous is None ||
            previous is Some({ kind: FixedText, .. }) ||
            (previous is Some(p) && p.modifier != None) ||
            needs_grouping ||
            part.prefix != ""
          ) {
          out.write_char('*')
        } else {
          out.write_string("(.*)")
        }
      _ => ()
    }
    if part.kind == SegmentWildcard &&
      custom_name &&
      part.suffix != "" &&
      part.suffix.get_char(0) is Some(c) &&
      is_name_char(c, false) {
      out.write_char('\\')
    }
    out.write_string(escape_pattern(part.suffix))
    if needs_grouping {
      out.write_char('}')
    }
    out.write_string(modifier_text(part.modifier))
  }
  out.to_string()
}
