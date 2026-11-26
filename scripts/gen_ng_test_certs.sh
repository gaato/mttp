#!/usr/bin/env bash
# Writes {root.pem,localhost.pem,localhost.key} into mttp_ng/testdata: a
# test root, a certificate for localhost and 127.0.0.1 under it, and that
# certificate's key, for the local HTTPS servers of gaato/mttp_ng's tests
# (Node's node:http2 and mttp_ng's own). The clients trust the root through
# Trust::PemFile, so no test turns certificate checking off. Valid from 2020
# to 2040, P-256 keys, issued by OpenSSL 3.4 or later
# (-not_before/-not_after). Rerun it rather than editing the output. Each
# run makes new keys, so the gates do not compare the committed files with a
# fresh run as they do for scripts/gen_*.mbtx.
#
# Bash rather than .mbtx: it only runs openssl.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
start=20200101000000Z
end=20400101000000Z

openssl ecparam -name prime256v1 -genkey -noout -out "$work/root.ec"
openssl pkcs8 -topk8 -nocrypt -in "$work/root.ec" -out "$work/root.key"
openssl req -new -key "$work/root.key" -subj "/CN=mttp_ng test root" \
  -out "$work/root.csr"
openssl x509 -req -in "$work/root.csr" -key "$work/root.key" \
  -not_before "$start" -not_after "$end" -sha256 \
  -extfile <(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n') \
  -out "$work/root.pem"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/leaf.ec"
openssl pkcs8 -topk8 -nocrypt -in "$work/leaf.ec" -out "$work/leaf.key"
openssl req -new -key "$work/leaf.key" -subj "/CN=localhost" -out "$work/leaf.csr"
openssl x509 -req -in "$work/leaf.csr" -CA "$work/root.pem" -CAkey "$work/root.key" \
  -not_before "$start" -not_after "$end" -sha256 \
  -extfile <(printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n') \
  -out "$work/leaf.pem"

for out in mttp_ng/testdata; do
  mkdir -p "$out"
  cp "$work/root.pem" "$out/root.pem"
  cp "$work/leaf.pem" "$out/localhost.pem"
  cp "$work/leaf.key" "$out/localhost.key"
  echo "wrote $out/root.pem, localhost.pem and localhost.key"
done
