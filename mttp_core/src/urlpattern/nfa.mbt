// Matching a part list without regular expressions. Section 2.2 turns parts
// into a regular expression; the same expression is built here as a
// Thompson NFA and run over the input once, in time linear in the input
// times the pattern, with no backtracking. Only whether the whole input
// matches is needed, not the groups, so lazy and greedy quantifiers are the
// same.

///|
/// What one step of the automaton reads.
priv enum Step {
  /// This code point.
  Literal(Char)
  /// Any code point but this one: a segment wildcard with a delimiter.
  Except(Char)
  /// Any code point: a segment wildcard without a delimiter (`[^]`).
  Any
  /// Any code point but a line terminator: the full wildcard (`.`).
  Dot
}

///|
priv enum Node {
  Read(Step, Int32)
  Split(Int32, Int32)
  Accept
}

///|
/// The expression of section 2.2, as a tree.
priv enum Expr {
  Text(String)
  Read(Step)
  Seq(Array[Expr])
  Optional(Expr)
  Star(Expr)
  Plus(Expr)
}

///|
priv struct Matcher {
  nodes : Array[Node]
  start : Int32
}

///|
fn with_modifier(e : Expr, m : Modifier) -> Expr {
  match m {
    None => e
    Optional => Optional(e)
    ZeroOrMore => Star(e)
    OneOrMore => Plus(e)
  }
}

///|
/// The expression `parts` stand for, as "generate a regular expression and
/// name list" builds it.
fn expr_of_parts(parts : Array[Part], options : Options) -> Expr {
  let seq = []
  for part in parts {
    if part.kind == FixedText {
      seq.push(with_modifier(Text(part.value), part.modifier))
      continue
    }
    let value : Expr = match part.kind {
      SegmentWildcard =>
        match options.delimiter {
          Some(d) => Plus(Read(Except(d)))
          None => Plus(Read(Any))
        }
      // A regexp part never reaches here: compile refuses them.
      _ => Star(Read(Dot))
    }
    if part.prefix == "" && part.suffix == "" {
      seq.push(with_modifier(value, part.modifier))
      continue
    }
    let prefix = Text(part.prefix)
    let suffix = Text(part.suffix)
    match part.modifier {
      None | Optional =>
        seq.push(with_modifier(Seq([prefix, value, suffix]), part.modifier))
      ZeroOrMore | OneOrMore => {
        let repeated = Seq([
          prefix,
          value,
          Star(Seq([suffix, prefix, value])),
          suffix,
        ])
        seq.push(
          if part.modifier == ZeroOrMore {
            Optional(repeated)
          } else {
            repeated
          },
        )
      }
    }
  }
  Seq(seq)
}

///|
/// Adds the nodes of `e` so that they continue at `next`; returns where
/// they start.
fn build(nodes : Array[Node], e : Expr, next : Int32) -> Int32 {
  match e {
    Text(s) => {
      let chars = s.to_array()
      let mut at = next
      for i = chars.length() - 1; i >= 0; i = i - 1 {
        nodes.push(Read(Literal(chars[i]), at))
        at = nodes.length() - 1
      }
      at
    }
    Read(step) => {
      nodes.push(Read(step, next))
      nodes.length() - 1
    }
    Seq(items) => {
      let mut at = next
      for i = items.length() - 1; i >= 0; i = i - 1 {
        at = build(nodes, items[i], at)
      }
      at
    }
    Optional(inner) => {
      let body = build(nodes, inner, next)
      nodes.push(Split(body, next))
      nodes.length() - 1
    }
    Star(inner) => {
      // The split comes first so the body can loop back to it.
      nodes.push(Split(-1, next))
      let split = nodes.length() - 1
      let body = build(nodes, inner, split)
      nodes[split] = Split(body, next)
      split
    }
    Plus(inner) => {
      nodes.push(Split(-1, next))
      let split = nodes.length() - 1
      let body = build(nodes, inner, split)
      nodes[split] = Split(body, next)
      body
    }
  }
}

///|
fn Matcher::new(parts : Array[Part], options : Options) -> Matcher {
  let nodes = [Accept]
  let start = build(nodes, expr_of_parts(parts, options), 0)
  { nodes, start, }
}

///|
fn reads(step : Step, c : Char) -> Bool {
  match step {
    Literal(x) => c == x
    Except(d) => c != d
    Any => true
    Dot => !(c is ('\n' | '\r' | '\u{2028}' | '\u{2029}'))
  }
}

///|
/// Adds `node` and what it reaches without reading to `set`; `mark` keeps
/// each node from being added twice in one step.
fn Matcher::add(
  self : Matcher,
  set : Array[Int32],
  mark : FixedArray[Int32],
  generation : Int32,
  node : Int32,
) -> Unit {
  let stack = [node]
  while stack.pop() is Some(n) {
    if mark[n] == generation {
      continue
    }
    mark[n] = generation
    match self.nodes[n] {
      Split(a, b) => {
        stack.push(b)
        stack.push(a)
      }
      _ => set.push(n)
    }
  }
}

///|
/// Whether the whole of `input` matches.
fn Matcher::matches(self : Matcher, input : String) -> Bool {
  let mark = FixedArray::make(self.nodes.length(), -1)
  let mut generation = 0
  let mut current = []
  self.add(current, mark, generation, self.start)
  for c in input {
    generation += 1
    let next = []
    for n in current {
      if self.nodes[n] is Read(step, to) && reads(step, c) {
        self.add(next, mark, generation, to)
      }
    }
    if next.is_empty() {
      return false
    }
    current = next
  }
  current.iter().any(n => self.nodes[n] is Accept)
}
