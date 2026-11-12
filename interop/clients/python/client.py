"""Python httpx against the mttp interop server, directly or through a
reverse proxy. interop/run.mbtx runs it as

    client.py <base> <direct> <case,case,...>

where <base> is where the server's endpoints are (http://127.0.0.1:39000
directly, or a proxy's /up prefix) and <direct> the server itself. It prints
`CASE <id> ok|fail <detail>` per case. httpx versions are pinned with hashes
in requirements.txt.
"""

import concurrent.futures
import sys

import httpx


def pattern(n):
    """interop/pattern's binary: byte i is (7i + i // 256) mod 256, so block k
    of 256 bytes is the first block with k added to every byte."""
    blocks = [bytes((7 * j + k) & 0xFF for j in range(256)) for k in range(256)]
    whole = b"".join(blocks[k & 0xFF] for k in range(n // 256 + 1))
    return whole[:n]


def digest(data):
    """interop/pattern's Digest summary."""
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return f"{len(data)}:{h:08x}"


def echoed(body, key):
    for line in body.decode("latin-1").split("\n"):
        if line.startswith(key + " "):
            return line[len(key) + 1 :]
    return "?"


class Failed(Exception):
    pass


def want(ok, what):
    if not ok:
        raise Failed(what)


def chunks(data, size=65536):
    """A generator body: httpx sends it chunked, having no length."""
    for i in range(0, len(data), size):
        yield data[i : i + size]


def upload(client, base, content, expected, headers=None):
    r = client.post(base + "/echo", content=content, headers=headers or {})
    want(r.status_code == 200, f"status {r.status_code}")
    received = echoed(r.content, "body")
    want(received == expected, f"the server got {received}")
    return f"{echoed(r.content, 'framing')}, {received}"


def run(case, base, client):
    if case == "get":
        r = client.get(base + "/conn")
        want(r.status_code == 200, f"status {r.status_code}")
        return r.text.strip()
    if case in ("reuse", "upstream-reuse"):
        # reuse: one client, one connection to the server. upstream-reuse:
        # a client per request, which the proxy should still serve over one
        # connection to the server.
        peers = []
        for _ in range(2):
            if case == "upstream-reuse":
                with httpx.Client() as fresh:
                    peers.append(fresh.get(base + "/conn").text.strip())
            else:
                peers.append(client.get(base + "/conn").text.strip())
        want(peers[0] == peers[1], f"peers {peers}")
        return "peer " + peers[0]
    if case == "chunked-upload":
        payload = pattern(1 << 20)
        return upload(client, base, chunks(payload), digest(payload))
    if case == "large-upload":
        # 4 MiB, not the 16 the other clients send: the digest is pure Python.
        payload = pattern(4 << 20)
        return upload(client, base, payload, digest(payload))
    if case == "expect-early-body":
        # httpx does not wait for 100 Continue: the body follows the head at
        # once, and the server's 100 arrives after it, if at all.
        payload = pattern(1 << 20)
        return upload(
            client, base, payload, digest(payload), {"Expect": "100-continue"}
        )
    if case == "stream":
        with client.stream("GET", base + "/stream?pieces=16&size=4096&delay_ms=10") as r:
            body = b"".join(r.iter_raw())
        want(digest(body) == digest(pattern(16 * 4096)), f"body {digest(body)}")
        return digest(body)
    if case == "head":
        r = client.head(base + "/bytes?n=1000")
        want(
            r.status_code == 200
            and r.headers.get("content-length") == "1000"
            and r.content == b"",
            f"status {r.status_code}, {r.headers}, {len(r.content)} body bytes",
        )
        nxt = client.get(base + "/bytes?n=10")
        want(nxt.content == pattern(10), f"next body {nxt.content!r}")
        return "length 1000, no body"
    if case == "no-content":
        r = client.get(base + "/status/204")
        want(r.status_code == 204 and r.content == b"", f"status {r.status_code}")
        nxt = client.get(base + "/bytes?n=10")
        want(nxt.content == pattern(10), f"next body {nxt.content!r}")
        return "204"
    if case == "parallel":
        expected = digest(pattern(100000))

        def one(_):
            r = client.get(base + "/bytes?n=100000")
            want(digest(r.content) == expected, f"body {digest(r.content)}")

        with concurrent.futures.ThreadPoolExecutor(16) as pool:
            list(pool.map(one, range(16)))
        return "16 concurrent requests"
    raise Failed("unknown case")


def main():
    if len(sys.argv) != 4:
        print("usage: client.py <base> <direct> <case,...>")
        sys.exit(2)
    base = sys.argv[1]
    limits = httpx.Limits(max_connections=32, max_keepalive_connections=32)
    with httpx.Client(timeout=30, limits=limits) as client:
        for case in sys.argv[3].split(","):
            try:
                detail = run(case, base, client)
                print(f"CASE {case} ok {detail}", flush=True)
            except Exception as error:  # every failure is a result
                print(f"CASE {case} fail {type(error).__name__}: {error}", flush=True)


if __name__ == "__main__":
    main()
