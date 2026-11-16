// The constructor string parser (section 1.6): splits a pattern written as
// one string into its components, on lenient tokens.

///|
#derive(Eq)
priv enum State {
  Init
  Protocol
  Authority
  Username
  Password
  Hostname
  Port
  Pathname
  Search
  Hash
  Done
}

///|
priv struct CtorParser {
  input : Array[Char]
  tokens : Array[Token]
  result : PatternInit
  mut component_start : Int32
  mut token_index : Int32
  mut token_increment : Int32
  mut group_depth : Int32
  mut ipv6_depth : Int32
  mut protocol_is_special : Bool
  mut state : State
}

///|
fn CtorParser::safe_token(self : CtorParser, index : Int32) -> Token {
  if index < self.tokens.length() {
    self.tokens[index]
  } else {
    self.tokens[self.tokens.length() - 1]
  }
}

///|
fn CtorParser::is_char(
  self : CtorParser,
  index : Int32,
  value : String,
) -> Bool {
  let token = self.safe_token(index)
  token.value == value && token.kind is (Char | EscapedChar | InvalidChar)
}

///|
fn CtorParser::at(self : CtorParser, value : String) -> Bool {
  self.is_char(self.token_index, value)
}

///|
fn CtorParser::is_search_prefix(self : CtorParser) -> Bool {
  if self.at("?") {
    return true
  }
  if self.tokens[self.token_index].value != "?" {
    return false
  }
  let previous = self.token_index - 1
  if previous < 0 {
    return true
  }
  !(self.safe_token(previous).kind is (Name | Regexp | Close | Asterisk))
}

///|
fn CtorParser::component_string(self : CtorParser) -> String {
  let end = self.tokens[self.token_index].index
  let start = self.safe_token(self.component_start).index
  String::from_array(self.input[start:end])
}

///|
fn CtorParser::set_component(
  self : CtorParser,
  state : State,
  value : String,
) -> Unit {
  let r = self.result
  match state {
    Protocol => r.protocol = Some(value)
    Username => r.username = Some(value)
    Password => r.password = Some(value)
    Hostname => r.hostname = Some(value)
    Port => r.port = Some(value)
    Pathname => r.pathname = Some(value)
    Search => r.search = Some(value)
    Hash => r.hash = Some(value)
    _ => ()
  }
}

///|
fn CtorParser::change_state(
  self : CtorParser,
  next : State,
  skip : Int32,
) -> Unit {
  let state = self.state
  if !(state is (Init | Authority | Done)) {
    self.set_component(state, self.component_string())
  }
  if state != Init && next != Done {
    let r = self.result
    if state is (Protocol | Authority | Username | Password) &&
      next is (Port | Pathname | Search | Hash) &&
      r.hostname is None {
      r.hostname = Some("")
    }
    if state is (Protocol | Authority | Username | Password | Hostname | Port) &&
      next is (Search | Hash) &&
      r.pathname is None {
      r.pathname = Some(if self.protocol_is_special { "/" } else { "" })
    }
    if state
      is (Protocol
      | Authority
      | Username
      | Password
      | Hostname
      | Port
      | Pathname) &&
      next is Hash &&
      r.search is None {
      r.search = Some("")
    }
  }
  self.state = next
  self.token_index += skip
  self.component_start = self.token_index
  self.token_increment = 0
}

///|
fn CtorParser::rewind(self : CtorParser) -> Unit {
  self.token_index = self.component_start
  self.token_increment = 0
}

///|
fn CtorParser::rewind_and_set(self : CtorParser, state : State) -> Unit {
  self.rewind()
  self.state = state
}

///|
let special_schemes : Array[String] = [
  "ftp", "file", "http", "https", "ws", "wss",
]

///|
fn CtorParser::compute_protocol_is_special(
  self : CtorParser,
) -> Unit raise PatternError {
  let component = compile_component(
    self.component_string(),
    canonicalize_protocol,
    default_options,
  )
  self.protocol_is_special = special_schemes
    .iter()
    .any(s => component.matches(s))
}

///|
/// Splits `input` into the components it writes, as "parse a constructor
/// string" does.
fn parse_constructor_string(input : String) -> PatternInit raise PatternError {
  let chars = input.to_array()
  let p : CtorParser = {
    input: chars,
    tokens: tokenize(chars, true),
    result: PatternInit::new(),
    component_start: 0,
    token_index: 0,
    token_increment: 1,
    group_depth: 0,
    ipv6_depth: 0,
    protocol_is_special: false,
    state: Init,
  }
  while p.token_index < p.tokens.length() {
    p.token_increment = 1
    if p.tokens[p.token_index].kind == End {
      if p.state == Init {
        p.rewind()
        if p.at("#") {
          p.change_state(Hash, 1)
        } else if p.is_search_prefix() {
          p.change_state(Search, 1)
        } else {
          p.change_state(Pathname, 0)
        }
        p.token_index += p.token_increment
        continue
      }
      if p.state == Authority {
        p.rewind_and_set(Hostname)
        p.token_index += p.token_increment
        continue
      }
      p.change_state(Done, 0)
      break
    }
    if p.tokens[p.token_index].kind == Open {
      p.group_depth += 1
      p.token_index += p.token_increment
      continue
    }
    if p.group_depth > 0 {
      if p.tokens[p.token_index].kind == Close {
        p.group_depth -= 1
      } else {
        p.token_index += p.token_increment
        continue
      }
    }
    match p.state {
      Init => if p.at(":") { p.rewind_and_set(Protocol) }
      Protocol =>
        if p.at(":") {
          p.compute_protocol_is_special()
          let (next, skip) = if p.is_char(p.token_index + 1, "/") &&
            p.is_char(p.token_index + 2, "/") {
            (Authority, 3)
          } else if p.protocol_is_special {
            (Authority, 1)
          } else {
            (Pathname, 1)
          }
          p.change_state(next, skip)
        }
      Authority =>
        if p.at("@") {
          p.rewind_and_set(Username)
        } else if p.at("/") || p.is_search_prefix() || p.at("#") {
          p.rewind_and_set(Hostname)
        }
      Username =>
        if p.at(":") {
          p.change_state(Password, 1)
        } else if p.at("@") {
          p.change_state(Hostname, 1)
        }
      Password => if p.at("@") { p.change_state(Hostname, 1) }
      Hostname =>
        if p.at("[") {
          p.ipv6_depth += 1
        } else if p.at("]") {
          p.ipv6_depth -= 1
        } else if p.at(":") && p.ipv6_depth == 0 {
          p.change_state(Port, 1)
        } else if p.at("/") {
          p.change_state(Pathname, 0)
        } else if p.is_search_prefix() {
          p.change_state(Search, 1)
        } else if p.at("#") {
          p.change_state(Hash, 1)
        }
      Port =>
        if p.at("/") {
          p.change_state(Pathname, 0)
        } else if p.is_search_prefix() {
          p.change_state(Search, 1)
        } else if p.at("#") {
          p.change_state(Hash, 1)
        }
      Pathname =>
        if p.is_search_prefix() {
          p.change_state(Search, 1)
        } else if p.at("#") {
          p.change_state(Hash, 1)
        }
      Search => if p.at("#") { p.change_state(Hash, 1) }
      Hash | Done => ()
    }
    p.token_index += p.token_increment
  }
  if p.result.hostname is Some(_) && p.result.port is None {
    p.result.port = Some("")
  }
  p.result
}
