# Bounded test generators

The package provides six small primitives for caller-seeded quickcheck tests:

| Function | Input space |
|---|---|
| `each_split` | Every two-piece byte partition, including empty ends; visits rather than retaining all partitions |
| `byte_chunks` | One byte per chunk, including splits inside UTF-8 sequences |
| `chunks` | Random nonempty partitions that concatenate to the caller's bytes |
| `text` | ASCII, whitespace, multibyte text, combining marks and unpaired UTF-16 surrogates; at most 128 pieces (256 UTF-16 units) |
| `headers` | Ordered duplicates and mixed-case names; at most 32 pairs, for lookup and persistence tests rather than wire-valid generation |
| `invalid_url` | Raw URLs containing controls or spaces that send-time validation must refuse |

Quickcheck's explicit seed makes samples reproducible on every target. No
generator reads a global random source. Byte partition helpers scale with the
caller-owned input; their callers choose the fixture size. Protocol-specific
valid values and expected errors stay with the parser's corpus or contract
tests, rather than being guessed by a generic request generator.
