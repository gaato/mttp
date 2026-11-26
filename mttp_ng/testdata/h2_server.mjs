// The HTTP/2 server of gaato/mttp_ng's tests,
// on Node's node:http2: one cleartext listener spoken to with prior
// knowledge (h2c), one TLS listener that offers h2 and http/1.1 by ALPN, and
// an HTTP proxy, all on 127.0.0.1; and, for the HTTP/1.1 fallback of
// gaato/mttp_ng, a cleartext HTTP/1.1 listener (h1) and a TLS one that
// offers only http/1.1 by ALPN (tls11), with the same paths. It prints
// {"h2c":PORT,"tls":PORT,"proxy":PORT,"h1":PORT,"tls11":PORT} on one line
// once all listen. The proxy tunnels CONNECT to the named port of 127.0.0.1 and
// forwards absolute-form requests there, adding x-via-proxy: yes to the
// forwarded answers; it answers 407 to a CONNECT or request for the host
// deny.invalid, and answers a request for echo.invalid itself (200, "via
// proxy", x-target: the request target it got). The other two listeners
// answer by path:
//
//   /hello              200 "hello"
//   /trailers           200, the request body and its x-checksum trailer
//                       ("none" without), then the trailer grpc-status: 0
//   /echo               200, the request body; x-method, x-fields (the
//                       request fields as JSON), x-received (body bytes) and
//                       x-target (the request target as it arrived)
//   /status/N           status N, empty
//   /redirect           302 to /hello
//   /gzip               200, gzip-coded "hello gzip" with content-encoding
//   /big/N              200, N bytes of "a"
//   /big-head/N         200 with an N-byte x-pad field
//   /refuse             resets the stream with REFUSED_STREAM, no answer
//   /goaway             GOAWAY naming an earlier stream, so this one is not
//                       processed, and the connection closed 100 ms later
//   /reset-body         200, ten bytes, then INTERNAL_ERROR on the stream
//   /hang               never answers
//   /stall              200 and its head, then nothing more
//   /session            200, the connection's number (1 for the first one)
//   /wait/MS            200 after MS milliseconds
//   /drop               closes the connection without an answer, on every
//                       request after the first of its connection (the
//                       first gets 200 "kept"), and counts the drops
//                       /drop?close=1 first closes both listeners, so that
//                       a new connection is refused
//   /drops              200, how many /drop requests were dropped so far
//   /early/N            status N at once, without reading the request body;
//                       over HTTP/2 the stream then ends with NO_ERROR, over
//                       HTTP/1.1 the connection closes
//
// --max-streams N sets SETTINGS_MAX_CONCURRENT_STREAMS. The process ends
// when its stdin closes, so a test that dies leaves no server behind.
import http from "node:http";
import https from "node:https";
import http2 from "node:http2";
import net from "node:net";
import fs from "node:fs";
import zlib from "node:zlib";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const settings = {};
for (let i = 0; i < args.length; i += 2) {
  if (args[i] === "--max-streams") settings.maxConcurrentStreams = Number(args[i + 1]);
}

let sessions = 0;
let drops = 0;
const seen = new WeakMap();
const ids = new WeakMap();
const { NGHTTP2_REFUSED_STREAM, NGHTTP2_INTERNAL_ERROR, NGHTTP2_NO_ERROR } = http2.constants;

function answer(req, res) {
  const url = new URL(req.url, "http://x");
  const parts = url.pathname.split("/").filter(Boolean);
  const stream = req.stream;
  switch (parts[0]) {
    case "hello":
      res.writeHead(200, { "content-type": "text/plain" });
      return res.end("hello");
    case "trailers": {
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const sum = req.trailers["x-checksum"] ?? "none";
        res.writeHead(200);
        res.addTrailers({ "grpc-status": "0" });
        res.end(Buffer.concat(chunks).toString() + " " + sum);
      });
      return;
    }
    case "echo": {
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const body = Buffer.concat(chunks);
        res.writeHead(200, {
          "x-method": req.method,
          "x-fields": JSON.stringify(req.headers),
          "x-received": String(body.length),
          "x-target": req.url,
        });
        res.end(body);
      });
      return;
    }
    case "status":
      res.writeHead(Number(parts[1]));
      return res.end();
    case "redirect":
      res.writeHead(302, { location: "/hello" });
      return res.end();
    case "gzip":
      res.writeHead(200, { "content-encoding": "gzip" });
      return res.end(zlib.gzipSync("hello gzip"));
    case "big": {
      let left = Number(parts[1]);
      res.writeHead(200, { "content-length": String(left) });
      const piece = Buffer.alloc(16384, "a");
      const pump = () => {
        while (left > 0) {
          const n = Math.min(left, piece.length);
          left -= n;
          if (!res.write(piece.subarray(0, n))) return res.once("drain", pump);
        }
        res.end();
      };
      return pump();
    }
    case "big-head":
      res.writeHead(200, { "x-pad": "p".repeat(Number(parts[1])) });
      return res.end();
    case "refuse":
      return stream.close(NGHTTP2_REFUSED_STREAM);
    case "goaway": {
      // Only the first connection goes away, so a resend can succeed.
      const session = stream.session;
      if (!ids.has(session)) ids.set(session, ++sessions);
      if (ids.get(session) !== 1) {
        res.writeHead(200);
        return res.end("after goaway");
      }
      session.goaway(NGHTTP2_NO_ERROR, Math.max(0, stream.id - 2));
      return setTimeout(() => session.destroy(), 100);
    }
    case "reset-body":
      res.writeHead(200);
      res.write("0123456789");
      return setTimeout(() => stream.close(NGHTTP2_INTERNAL_ERROR), 50);
    case "hang":
      return;
    case "stall":
      res.writeHead(200);
      return res.write("");
    case "session": {
      const session = stream ? stream.session : req.socket;
      if (!ids.has(session)) ids.set(session, ++sessions);
      res.writeHead(200);
      return res.end(String(ids.get(session)));
    }
    case "early":
      res.writeHead(Number(parts[1]), stream ? {} : { connection: "close" });
      res.end("early");
      if (stream) stream.close(http2.constants.NGHTTP2_NO_ERROR);
      return;
    case "drop": {
      const conn = stream ? stream.session : req.socket;
      seen.set(conn, (seen.get(conn) || 0) + 1);
      if (seen.get(conn) === 1) {
        res.writeHead(200);
        return res.end("kept");
      }
      drops++;
      if (url.searchParams.get("close") === "1") {
        h2c.close();
        tls.close();
      }
      return stream ? stream.session.destroy() : req.socket.destroy();
    }
    case "drops":
      res.writeHead(200);
      return res.end(String(drops));
    case "wait":
      return setTimeout(() => {
        res.writeHead(200);
        res.end("waited");
      }, Number(parts[1]));
    default:
      res.writeHead(404);
      return res.end();
  }
}

const h2c = http2.createServer({ settings }, answer);
const tls = http2.createSecureServer(
  {
    settings,
    allowHTTP1: true,
    key: fs.readFileSync(path.join(here, "localhost.key")),
    cert: fs.readFileSync(path.join(here, "localhost.pem")),
  },
  answer,
);
const h1 = http.createServer(answer);
const tls11 = https.createServer(
  {
    ALPNProtocols: ["http/1.1"],
    key: fs.readFileSync(path.join(here, "localhost.key")),
    cert: fs.readFileSync(path.join(here, "localhost.pem")),
  },
  answer,
);
// The proxy: CONNECT tunnels and absolute-form forwarding, to this machine
// only; the host deny.invalid is refused with 407.
const proxy = http.createServer((req, res) => {
  const target = new URL(req.url);
  if (target.hostname === "deny.invalid") {
    res.writeHead(407, { "proxy-authenticate": "Basic" });
    return res.end();
  }
  if (target.hostname === "echo.invalid") {
    res.writeHead(200, { "x-via-proxy": "yes", "x-target": req.url });
    return res.end("via proxy");
  }
  const upstream = http.request(
    {
      host: "127.0.0.1",
      port: target.port,
      method: req.method,
      path: target.pathname + target.search,
      headers: req.headers,
    },
    (answer) => {
      res.writeHead(answer.statusCode, { ...answer.headers, "x-via-proxy": "yes" });
      answer.pipe(res);
    },
  );
  upstream.on("error", () => {
    res.writeHead(502);
    res.end();
  });
  req.pipe(upstream);
});
proxy.on("connect", (req, socket, head) => {
  const [host, port] = req.url.split(":");
  if (host === "deny.invalid") {
    socket.end("HTTP/1.1 407 Proxy Authentication Required\r\ncontent-length: 0\r\n\r\n");
    return;
  }
  const upstream = net.connect(Number(port), "127.0.0.1", () => {
    socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});
await Promise.all([
  new Promise((ok) => h2c.listen(0, "127.0.0.1", ok)),
  new Promise((ok) => tls.listen(0, "127.0.0.1", ok)),
  new Promise((ok) => proxy.listen(0, "127.0.0.1", ok)),
  new Promise((ok) => h1.listen(0, "127.0.0.1", ok)),
  new Promise((ok) => tls11.listen(0, "127.0.0.1", ok)),
]);
process.stdout.write(
  JSON.stringify({
    h2c: h2c.address().port,
    tls: tls.address().port,
    proxy: proxy.address().port,
    h1: h1.address().port,
    tls11: tls11.address().port,
  }) + "\n",
);
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
