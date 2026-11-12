#!/bin/sh
# curl against the mttp interop server, directly or through a reverse proxy.
# It runs in the curl image interop/images.tsv pins, with the document root
# of interop/mttp_server's `www` at /www (the uploads and their digests).
# interop/run.mbtx runs it as
#
#   cases.sh <base> <direct> <case,case,...>
#
# where <base> is where the server's endpoints are (http://127.0.0.1:39000
# directly, or a proxy's /up prefix) and <direct> the server itself. It
# prints `CASE <id> ok|fail <detail>` per case.
base=$1
direct=$2
cases=$3

result() {
  if [ "$1" = ok ]; then shift; echo "CASE $id ok $*"; else shift; echo "CASE $id fail $*"; fi
}
digest_of() { grep "^$1 " /www/digests.txt | cut -d' ' -f2; }
echoed() { printf '%s\n' "$1" | grep "^$2 " | cut -d' ' -f2-; }
c() { curl -sS --max-time 30 "$@"; }

# Checks an /echo answer against the digest of a file in /www.
uploaded() {
  got=$(echoed "$1" body)
  want=$(digest_of "$2")
  if [ "$got" = "$want" ]; then
    result ok "$(echoed "$1" framing), $got $3"
  else
    result fail "the server got $got, not $want"
  fi
}

for id in $(echo "$cases" | tr ',' ' '); do
  case $id in
  get)
    out=$(c -f "$base/conn") && result ok "$out" || result fail "curl failed"
    ;;
  reuse)
    # One curl, two URLs: one connection.
    out=$(c -f "$base/conn" "$base/conn" | tr '\n' ' ')
    set -- $out
    [ -n "$1" ] && [ "$1" = "$2" ] && result ok "peer $1" || result fail "peers $out"
    ;;
  upstream-reuse)
    # Two curls, two connections to the proxy: one to the server.
    a=$(c -f "$base/conn")
    b=$(c -f "$base/conn")
    [ -n "$a" ] && [ "$a" = "$b" ] && result ok "peer $a" || result fail "peers $a $b"
    ;;
  chunked-upload)
    out=$(c -f -H 'Transfer-Encoding: chunked' -H 'Expect:' --data-binary @/www/upload.bin "$base/echo")
    uploaded "$out" upload.bin
    ;;
  large-upload)
    out=$(c -f --data-binary @/www/large.bin "$base/echo")
    uploaded "$out" large.bin
    ;;
  expect)
    # curl asks for 100 Continue before a body over 1 MiB.
    out=$(c -f -v --data-binary @/www/upload.bin "$base/echo" 2>/tmp/trace)
    if grep -q '^> Expect: 100-continue' /tmp/trace && grep -q '^< HTTP/1.1 100' /tmp/trace; then
      uploaded "$out" upload.bin "after 100 Continue"
    else
      result fail "no 100 Continue exchange: $(grep -E '^[<>] (Expect|HTTP)' /tmp/trace | tr '\n' ' ')"
    fi
    ;;
  http10)
    # A streamed answer to HTTP/1.0 cannot be chunked: it ends at the close.
    c -f -0 -D /tmp/head -o /tmp/body "$base/stream?pieces=4&size=1000"
    out=$(c -f --data-binary @/tmp/body "$direct/echo")
    if grep -qi '^transfer-encoding' /tmp/head; then
      result fail "chunked to HTTP/1.0"
    elif [ "$(echoed "$out" body)" = "$(digest_of binary-4000)" ]; then
      result ok "$(head -1 /tmp/head | tr -d '\r'), $(echoed "$out" body)"
    else
      result fail "body $(echoed "$out" body)"
    fi
    ;;
  http10-keepalive)
    out=$(c -f -0 -H 'Connection: keep-alive' "$base/conn" "$base/conn" | tr '\n' ' ')
    set -- $out
    [ -n "$1" ] && [ "$1" = "$2" ] && result ok "peer $1" || result fail "peers $out"
    ;;
  head)
    out=$(c -f -I "$base/bytes?n=1000" | tr -d '\r' | tr 'A-Z' 'a-z' | grep '^content-length:')
    [ "$out" = "content-length: 1000" ] && result ok "$out" || result fail "head: $out"
    ;;
  no-content)
    code=$(c -o /dev/null -w '%{http_code} %{size_download}' "$base/status/204")
    [ "$code" = "204 0" ] && result ok "$code" || result fail "$code"
    ;;
  *)
    result fail "unknown case"
    ;;
  esac
done
