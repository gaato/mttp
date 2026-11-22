// The HTTP/2 server of gaato/mttp_curl's tests, on Node's node:http2: one
// cleartext listener spoken to with prior knowledge (h2c) and one TLS
// listener that offers h2 and http/1.1 by ALPN, both on 127.0.0.1. It prints
// {"h2c":PORT,"tls":PORT} on one line once both listen, and then answers by
// path:
//
//   /hello              200 "hello"
//   /echo               200, the request body; x-method, x-fields (the
//                       request fields as JSON) and x-received (body bytes)
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
//
// --max-streams N sets SETTINGS_MAX_CONCURRENT_STREAMS. The process ends
// when its stdin closes, so a test that dies leaves no server behind.
import http2 from "node:http2";
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
    case "echo": {
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const body = Buffer.concat(chunks);
        res.writeHead(200, {
          "x-method": req.method,
          "x-fields": JSON.stringify(req.headers),
          "x-received": String(body.length),
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
await Promise.all([
  new Promise((ok) => h2c.listen(0, "127.0.0.1", ok)),
  new Promise((ok) => tls.listen(0, "127.0.0.1", ok)),
]);
process.stdout.write(
  JSON.stringify({ h2c: h2c.address().port, tls: tls.address().port }) + "\n",
);
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
