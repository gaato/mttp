// A local HTTP/1.1 peer for the WASI spike. Usage: node server.mjs <port>
import http from "node:http";

let closedEarly = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const ms = Number(url.searchParams.get("ms") ?? "0");
  switch (url.pathname) {
    case "/hello":
      res.end("hi");
      return;
    case "/echo": {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const body = Buffer.concat(chunks);
      res.setHeader("x-method", req.method);
      res.end(body);
      return;
    }
    case "/slow-head":
      await sleep(ms);
      res.end("late");
      return;
    case "/slow-body":
      res.setHeader("content-length", "10");
      res.write("12345");
      await sleep(ms);
      res.end("67890");
      return;
    case "/big": {
      const n = Number(url.searchParams.get("n"));
      res.setHeader("content-length", String(n));
      res.end(Buffer.alloc(n, 0x61));
      return;
    }
    case "/drip": {
      res.on("close", () => {
        if (!res.writableEnded) closedEarly++;
      });
      for (let i = 0; i < 100 && !res.destroyed; i++) {
        res.write("x");
        await sleep(50);
      }
      res.end();
      return;
    }
    case "/closed":
      res.end(String(closedEarly));
      return;
    default:
      res.statusCode = 404;
      res.end();
  }
});
server.listen(Number(process.argv[2] ?? "18765"), "127.0.0.1");
