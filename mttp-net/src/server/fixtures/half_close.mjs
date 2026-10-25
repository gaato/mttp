import assert from 'node:assert/strict';
import net from 'node:net';

const port = Number(process.argv[2].split(':').at(-1));
for (const framing of ['Content-Length: 4', 'Transfer-Encoding: chunked']) {
  const socket = net.connect({ host: '127.0.0.1', port, allowHalfOpen: true });
  const chunks = [];
  socket.setTimeout(2000, () => socket.destroy(new Error('response timed out')));
  const reply = new Promise((resolve, reject) => {
    socket.on('data', chunk => chunks.push(chunk));
    socket.on('error', reject);
    socket.on('end', () => resolve(Buffer.concat(chunks).toString()));
  });
  // end sends FIN after the complete request but keeps the readable half open.
  socket.end(`POST / HTTP/1.1\r\nHost: localhost\r\n${framing}\r\n\r\n` +
    (framing.startsWith('Content-Length') ? 'body' : '4\r\nbody\r\n0\r\n\r\n'));
  try {
    const response = await reply;
    assert.match(response, /^HTTP\/1\.1 200 /);
    assert.equal(response.split('\r\n\r\n')[1], 'body');
  } finally {
    socket.destroy();
  }
}
