# gaato/mttp_core/representation

Pure representation selection from [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110):
`evaluate_preconditions` follows section 13.2.2 for an existing representation.
If-Match uses strong comparison and suppresses If-Unmodified-Since;
If-None-Match uses weak comparison and suppresses If-Modified-Since.
Dates compare whole seconds. A matching If-None-Match returns NotModified for
GET/HEAD, Failed for other methods. Missing validators cannot match explicit
entity tags; `*` refers to existence, which this API assumes.
`not_modified` builds a bodyless 304 with validators and caller cache metadata.

`choose_range` supports one inclusive bytes range on GET. HEAD ignores Range.
An unknown unit, multiple ranges, malformed/overflowing integers or a field
larger than 1 KiB (or more than 100 ranges) selects Full. Valid but unsatisfiable
ranges select Unsatisfiable. If-Range accepts only a strong matching ETag or
an exact Last-Modified date, compared at HTTP's second precision.

`negotiate_media` limits Accept to 16 KiB of UTF-8 field values and 128 nonempty
items, raising TransportError(Invalid, Head) for malformed input or overflow.
The most specific matching range, including media parameters, sets an offer's
weight. Offers are then ranked by weight, specificity and caller order.
Repeated equally specific ranges use their lowest weight. Missing Accept
accepts the first offer; empty Accept accepts none. Parameters after `q` do
not constrain the media type. Quoted commas and semicolons are preserved.

```mbt check
///|
test "conditional and partial representation" {
  let validators = @representation.Validators::new(etag="\"v1\"")
  let head = @mttp_core.Request::get("/asset")
    .header("range", "bytes=-3")
    .head()
  assert_eq(
    @representation.evaluate_preconditions(head, validators),
    @representation.Proceed,
  )
  assert_eq(
    @representation.choose_range(head, 10L, validators),
    @representation.Partial(start=7L, end=9L),
  )
  let headers = @mttp_core.Headers::of([
    ("accept", "text/*;q=0.5, application/json"),
  ])
  assert_eq(
    @representation.negotiate_media(headers, ["text/plain", "application/json"]),
    @representation.Offer(1),
  )
}
```
