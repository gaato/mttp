import http from "node:http";

if (process.argv.length !== 3) {
  throw new Error("usage: server.mjs <port>");
}

const smallBody = Buffer.from("mttp benchmark\n");
const largeBody = Buffer.alloc(1024 * 1024, "x");
const server = http.createServer((request, response) => {
  let body;
  if (request.url === "/small") {
    body = smallBody;
  } else if (request.url === "/large") {
    body = largeBody;
  } else {
    response.writeHead(404, { "content-type": "text/plain" });
    response.end("not found\n");
    return;
  }
  response.writeHead(200, {
    "content-length": body.length,
    "content-type": "application/octet-stream",
  });
  response.end(body);
});

server.listen(Number(process.argv[2]), "127.0.0.1");
