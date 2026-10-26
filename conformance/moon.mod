// Unpublished HTTP conformance corpora, kept outside the consumer dependency
// graph because the vectors and fuzz harness are test data rather than API.
name = "gaato/mttp-conformance"

version = "0.0.0"

private = true

license = "Apache-2.0"

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/mttp@0.1.0",
}
