"""Raw-socket probes of HTTP/1.1 framing: request smuggling shapes,
pipelining and HTTP/1.0, sent to the mttp interop server directly or through
a reverse proxy. The standard library only. interop/run.mbtx runs it as

    probes.py <target host:port> <prefix> <server host:port> <case,case,...>

with <prefix> "" for the server itself and "/up" for a proxy in front of it.
It prints `CASE <id> ok|fail <detail>` per case.

Directly, every ambiguous shape must be refused as the mttp documentation
says (CONTRACT.md, "HTTP/1 codec"; mttp_core/src/h1server/README.mbt.md, "Strict
framing"): 400, or 501 for a transfer coding other than chunked, with exactly
one response and the connection closed, so that no byte after the head is
read as another request.

Through a proxy, the proxy may refuse a shape, or forward it in a form of its
own choosing. Each probe hides a request for `smuggled` where one reading of
the message would find it. A probe fails if that request, or more than one
request, reaches the server, or if the proxy forwards something the server
had to refuse as ambiguous; the server's /log says what reached it.
"""

import re
import socket
import sys
import urllib.request

HOST = "127.0.0.1"


def head(*lines):
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def smuggled(prefix):
    return head(f"GET {prefix}/smuggled HTTP/1.1", f"Host: {HOST}")


def ambiguous(fields, prefix, version="HTTP/1.1"):
    """A POST whose body, read by Content-Length, holds a request for
    `smuggled`, and read as chunked ends before it (CL.TE)."""
    body = b"0\r\n\r\n" + smuggled(prefix)
    fields = [f.replace("{len}", str(len(body))) for f in fields]
    return head(f"POST {prefix}/echo {version}", f"Host: {HOST}", *fields) + body


def te_cl(prefix):
    """Chunked, the request for `smuggled` inside the first chunk; read by
    the short Content-Length instead, it follows the message (TE.CL)."""
    inner = smuggled(prefix)
    body = b"%x\r\n" % len(inner) + inner + b"\r\n0\r\n\r\n"
    return head(
        f"POST {prefix}/echo HTTP/1.1",
        f"Host: {HOST}",
        "Transfer-Encoding: chunked",
        "Content-Length: 4",
    ) + body


def chunked(prefix, te, body):
    return head(f"POST {prefix}/echo HTTP/1.1", f"Host: {HOST}", te) + body


HELLO = b"5\r\nhello\r\n0\r\n\r\n"

# id: (request builder, status the server answers directly, valid). A
# refused probe must also get exactly one response and a closed connection;
# a valid one must reach the server with the body "hello".
PROBES = {
    "cl-te": (lambda p: ambiguous(["Content-Length: {len}", "Transfer-Encoding: chunked"], p), 400, False),
    "te-cl": (te_cl, 400, False),
    "cl-cl-same": (lambda p: ambiguous(["Content-Length: {len}", "Content-Length: {len}"], p), 400, False),
    "cl-cl-diff": (lambda p: ambiguous(["Content-Length: 5", "Content-Length: {len}"], p), 400, False),
    "cl-list": (lambda p: ambiguous(["Content-Length: 5, {len}"], p), 400, False),
    "cl-plus": (lambda p: ambiguous(["Content-Length: +{len}"], p), 400, False),
    "te-chunked-twice": (lambda p: ambiguous(["Transfer-Encoding: chunked, chunked"], p), 400, False),
    "te-two-fields": (lambda p: ambiguous(["Transfer-Encoding: chunked", "Transfer-Encoding: chunked"], p), 400, False),
    "te-gzip-chunked": (lambda p: ambiguous(["Transfer-Encoding: gzip, chunked"], p), 501, False),
    "te-identity": (lambda p: ambiguous(["Transfer-Encoding: identity"], p), 501, False),
    "te-xchunked-cl": (lambda p: ambiguous(["Content-Length: {len}", "Transfer-Encoding: xchunked"], p), 400, False),
    "te-space-before-colon": (lambda p: ambiguous(["Content-Length: {len}", "Transfer-Encoding : chunked"], p), 400, False),
    "te-obs-fold": (lambda p: ambiguous(["Content-Length: {len}", "Transfer-Encoding: identity", " chunked"], p), 400, False),
    "te-http10": (lambda p: ambiguous(["Transfer-Encoding: chunked"], p, "HTTP/1.0"), 400, False),
    # Line ends without CR. A lenient proxy may read it and forward it with
    # CRLF, so nothing hides behind it.
    "bare-lf": (lambda p: f"GET {p}/echo HTTP/1.1\nHost: {HOST}\n\n".encode(), 400, False),
    "chunk-size-0x": (lambda p: chunked(p, "Transfer-Encoding: chunked", b"0x5\r\nhello\r\n0\r\n\r\n" + smuggled(p)), 400, False),
    "chunk-size-overflow": (lambda p: chunked(p, "Transfer-Encoding: chunked", b"10000000000000005\r\nhello\r\n0\r\n\r\n" + smuggled(p)), 400, False),
    "chunk-bare-lf": (lambda p: chunked(p, "Transfer-Encoding: chunked", b"5\nhello\n0\n\n" + smuggled(p)), 400, False),
    "host-twice": (lambda p: head(f"GET {p}/echo HTTP/1.1", f"Host: {HOST}", "Host: other.test"), 400, False),
    "host-missing": (lambda p: head(f"GET {p}/echo HTTP/1.1"), 400, False),
    "nul-in-field": (lambda p: head(f"GET {p}/echo HTTP/1.1", f"Host: {HOST}", "X-Probe: a\x00b"), 400, False),
    # Valid shapes, which every party must accept.
    "te-tab": (lambda p: chunked(p, "Transfer-Encoding:\tchunked", HELLO), 200, True),
    "te-capitals": (lambda p: chunked(p, "Transfer-Encoding: Chunked", HELLO), 200, True),
    "chunk-extension": (lambda p: chunked(p, "Transfer-Encoding: chunked", b"5;name=value\r\nhello\r\n0\r\n\r\n"), 200, True),
}

STATUS = re.compile(rb"HTTP/1\.[01] (\d{3})")


def exchange(target, data, idle=0.5):
    """Sends `data` and reads until the peer closes or stays silent for
    `idle` seconds. Returns the bytes and whether the peer closed."""
    host, port = target.split(":")
    with socket.create_connection((host, int(port)), timeout=10) as s:
        s.sendall(data)
        s.settimeout(idle)
        received = b""
        while True:
            try:
                chunk = s.recv(65536)
            except (socket.timeout, TimeoutError):
                return received, False
            except ConnectionResetError:
                return received, True
            if not chunk:
                return received, True
            received += chunk


def parse(data):
    """The responses in `data`: (status, headers, body) for each one framed
    by Content-Length or chunked, then a close-delimited rest."""
    out = []
    while data:
        end = data.find(b"\r\n\r\n")
        if end < 0:
            break
        lines = data[:end].decode("latin-1").split("\r\n")
        m = re.match(r"HTTP/1\.[01] (\d{3})", lines[0])
        if not m:
            break
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        rest = data[end + 4 :]
        status = int(m.group(1))
        if "content-length" in headers:
            n = int(headers["content-length"])
            body, data = rest[:n], rest[n:]
        elif headers.get("transfer-encoding", "").lower() == "chunked":
            body = b""
            while True:
                line_end = rest.find(b"\r\n")
                size = int(rest[:line_end].split(b";")[0], 16)
                body += rest[line_end + 2 : line_end + 2 + size]
                rest = rest[line_end + 2 + size + 2 :]
                if size == 0:
                    break
            data = rest
        elif status in (204, 304) or 100 <= status < 200:
            body = b""
            data = rest
        else:
            body, data = rest, b""
        out.append((status, headers, body))
    return out


def pattern(n):
    return bytes((i * 7 + (i >> 8)) & 0xFF for i in range(n))


def server_log(server, reset=False):
    url = f"http://{server}/log" + ("?reset=1" if reset else "")
    with urllib.request.urlopen(url, timeout=10) as r:
        return [line for line in r.read().decode().split("\n") if line]


class Failed(Exception):
    pass


def want(ok, what):
    if not ok:
        raise Failed(what)


def probe_direct(target, case):
    build, status, valid = PROBES[case]
    data, closed = exchange(target, build(""))
    statuses = [int(s) for s in STATUS.findall(data)]
    if valid:
        responses = parse(data)
        want(statuses == [200], f"statuses {statuses}")
        want(b"body 5:4f9f2cab" in responses[0][2], f"echo {responses[0][2]!r}")
        return "200, body hello"
    want(statuses == [status], f"statuses {statuses}, expected [{status}]")
    want(closed, "the connection stayed open")
    return f"{status} and closed"


def probe_proxy(target, prefix, server, case):
    build, _, valid = PROBES[case]
    server_log(server, reset=True)
    data, _ = exchange(target, build(prefix))
    statuses = [int(s) for s in STATUS.findall(data)]
    log = server_log(server)
    reached = [line for line in log if not line.startswith("error")]
    errors = [line for line in log if line.startswith("error")]
    want(not any("smuggled" in line for line in log), f"a hidden request reached the server: {log}")
    want(len(reached) <= 1, f"{len(reached)} requests reached the server: {log}")
    # A proxy that streams the body and meets a bad chunk can only abort the
    # upstream request: a truncated body, which the server refuses. A head
    # the server refuses means the proxy forwarded an ambiguous one.
    aborted = [e for e in errors if "ended the request body early" in e]
    want(len(aborted) == len(errors), f"the proxy forwarded what the server refused: {errors}")
    if aborted:
        return f"aborted by the proxy mid-body, answered {statuses}"
    if valid:
        want(statuses == [200], f"a valid request got {statuses}")
        want(len(reached) == 1, "it did not reach the server")
        return f"forwarded as {reached[0].split(' ')[-1]}"
    if reached:
        return f"forwarded as {reached[0].split(' ')[-1]}, answered {statuses}"
    return f"refused by the proxy with {statuses}"


def pipeline(target, prefix):
    data, _ = exchange(
        target,
        head(f"GET {prefix}/bytes?n=5 HTTP/1.1", f"Host: {HOST}")
        + head(f"POST {prefix}/echo HTTP/1.1", f"Host: {HOST}", "Content-Length: 5")
        + b"hello"
        + head(f"GET {prefix}/bytes?n=7 HTTP/1.1", f"Host: {HOST}"),
    )
    responses = parse(data)
    want(len(responses) == 3, f"{len(responses)} responses: {data[:200]!r}")
    want(responses[0][2] == pattern(5), f"first body {responses[0][2]!r}")
    want(b"body 5:4f9f2cab" in responses[1][2], f"second body {responses[1][2]!r}")
    want(responses[2][2] == pattern(7), f"third body {responses[2][2]!r}")
    return "3 responses in order"


def http10(target, prefix):
    data, closed = exchange(
        target, head(f"GET {prefix}/stream?pieces=2&size=5 HTTP/1.0", f"Host: {HOST}")
    )
    responses = parse(data)
    want(len(responses) == 1, f"{len(responses)} responses")
    status, headers, body = responses[0]
    want(status == 200, f"status {status}")
    want("transfer-encoding" not in headers, f"chunked to HTTP/1.0: {headers}")
    want(body == pattern(10), f"body {body!r}")
    want(closed, "the connection stayed open without a length")
    return "200, close-delimited"


def http10_keepalive(target, prefix):
    data, _ = exchange(
        target,
        head(f"GET {prefix}/bytes?n=5 HTTP/1.0", f"Host: {HOST}", "Connection: keep-alive")
        + head(f"GET {prefix}/bytes?n=7 HTTP/1.0", f"Host: {HOST}"),
    )
    responses = parse(data)
    want(len(responses) == 2, f"{len(responses)} responses")
    want(responses[0][1].get("connection", "").lower() == "keep-alive", f"first head {responses[0][1]}")
    want(responses[1][2] == pattern(7), f"second body {responses[1][2]!r}")
    return "kept alive for a second request"


def main():
    if len(sys.argv) != 5:
        print("usage: probes.py <target host:port> <prefix> <server host:port> <case,...>")
        sys.exit(2)
    target, prefix, server, cases = sys.argv[1:]
    for case in cases.split(","):
        try:
            if case == "pipeline":
                detail = pipeline(target, prefix)
            elif case == "http10":
                detail = http10(target, prefix)
            elif case == "http10-keepalive":
                detail = http10_keepalive(target, prefix)
            elif case in PROBES:
                detail = probe_proxy(target, prefix, server, case) if prefix else probe_direct(target, case)
            else:
                raise Failed("unknown case")
            print(f"CASE {case} ok {detail}", flush=True)
        except Exception as error:  # every failure is a result
            print(f"CASE {case} fail {type(error).__name__}: {error}", flush=True)


if __name__ == "__main__":
    main()
