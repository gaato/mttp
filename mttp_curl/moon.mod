// gaato/mttp's Backend over libcurl: HTTP/1.1 and HTTP/2 by ALPN and, when
// asked, HTTP/3, under mttp's Client, on native. The policies (redirects,
// retries, cookies, decoding, deadlines) stay in gaato/mttp; this module only
// moves bytes. It links the system's libcurl, so scripts/modules.tsv puts it
// in the curl gate, which only the CI job that installs libcurl runs.

name = "gaato/mttp_curl"

version = "0.0.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "http2", "http3", "client", "backend", "curl" ]

description = "An HTTP/2 and HTTP/3 backend for gaato/mttp's Client over the system's libcurl, for native."

source = "src"

preferred_target = "native"

supported_targets = "native"

import {
  "gaato/mttp_core@0.3.2",
  "gaato/mttp@0.5.2",
}
