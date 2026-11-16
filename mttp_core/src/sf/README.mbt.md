# gaato/mttp_core/sf

[RFC 9651](https://www.rfc-editor.org/rfc/rfc9651) Structured Field Values
for HTTP: the parsing and serializing algorithms of its section 4, without
I/O, for fields such as `Use-As-Dictionary`, `Available-Dictionary`,
`Priority` and `Cache-Status`.

`parse_list`, `parse_dictionary` and `parse_item` take the field's lines as
they arrived, in order, and join them with `", "` as section 4.2 does; they
give `None` for anything the RFC's algorithm fails on, which a recipient
then treats as if the field were absent. `serialize_list`,
`serialize_dictionary`, `serialize_item` and `serialize_bare_item` give the
canonical text, or `None` for a value the field syntax cannot carry (a key
or token with a character it does not allow, a string outside printable
ASCII, a number with more than 15 digits). An empty List or Dictionary
serializes to `""`, which section 4.1 says to send as no field at all.

Decimals are held exactly, in thousandths: `Decimal(1500)` is 1.5. A parsed
Decimal has at most three fractional digits, as the RFC allows;
`decimal_from_string` rounds a longer one to three, ties to even, as section
4.1.5 serializes it. A Dictionary or Parameters keeps its keys in order;
when a key repeats, the first place and the last value stay, as section
4.2.2 says.

The parser reads each character once, finds a repeated key by hash rather
than by scanning the keys before it, and does not recurse: an Inner List
holds only Items, so the depth is fixed. Field size is bounded by the
caller, as the HTTP/1 codec bounds a head.

```mbt check
///|
test "read a Dictionary and write it back" {
  let fields = ["a=?0, b, c; foo=bar", "d=(1 2.5);x"]
  let dict = @sf.parse_dictionary(fields).unwrap()
  assert_eq(dict[1], ("b", Item(@sf.Item::of(Boolean(true)))))
  assert_eq(
    dict[3].1,
    InnerList([@sf.Item::of(Integer(1)), @sf.Item::of(Decimal(2500))], [
      ("x", Boolean(true)),
    ]),
  )
  assert_eq(
    @sf.serialize_dictionary(dict),
    Some("a=?0, b, c;foo=bar, d=(1 2.5);x"),
  )
  assert_eq(@sf.parse_item(["\"unterminated"]), None)
}
```
