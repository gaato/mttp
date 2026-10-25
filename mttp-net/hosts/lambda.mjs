import { Buffer } from 'node:buffer';

async function boundedBody(response, limit) {
  if (!response.body) return Buffer.alloc(0);
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) return Buffer.concat(chunks, length);
      if (value.byteLength > limit - length) throw new RangeError('Lambda response exceeds buffer limit');
      length += value.byteLength;
      chunks.push(Buffer.from(value));
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

// Function URLs have no waitUntil. Completion includes background work, so
// long deferred work delays the initial response on this host.
export function lambda(fetch, {maxRequestBytes = 1048576, maxResponseBytes = 4194304} = {}) {
  for (const value of [maxRequestBytes, maxResponseBytes]) {
    if (!Number.isSafeInteger(value) || value < 0) throw new RangeError('Invalid Lambda body limit');
  }
  return async event => {
    const encoded = event.body ?? '';
    const bytes = event.isBase64Encoded
      ? Math.floor(encoded.length / 4) * 3 - (encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0)
      : Buffer.byteLength(encoded, 'utf8');
    if (bytes > maxRequestBytes) return {statusCode: 413, body: ''};
    if (event.isBase64Encoded && !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
      return {statusCode: 400, body: ''};
    }
    const body = Buffer.from(encoded, event.isBase64Encoded ? 'base64' : 'utf8');
    const headers = new Headers(event.headers ?? {});
    if (event.cookies?.length) headers.set('cookie', event.cookies.join('; '));
    const domain = event.requestContext?.domainName ?? headers.get('host');
    const path = event.rawPath ?? '/';
    const query = event.rawQueryString ? `?${event.rawQueryString}` : '';
    const method = event.requestContext?.http?.method ?? 'GET';
    const request = new Request(`https://${domain}${path}${query}`, {
      method, headers, body: method === 'GET' || method === 'HEAD' ? undefined : body,
    });
    const tasks = [];
    let response;
    try {
      response = await fetch(request, promise => {
        // Attach rejection handling at registration, before awaiting response.
        tasks.push(Promise.resolve(promise).then(() => ({ok: true}), error => ({ok: false, error})));
      });
      const output = await boundedBody(response, maxResponseBytes);
      const cookies = response.headers.getSetCookie();
      return {
        statusCode: response.status,
        headers: Object.fromEntries([...response.headers].filter(([name]) => name !== 'set-cookie')),
        cookies,
        body: output.toString('base64'),
        isBase64Encoded: true,
      };
    } finally {
      const outcomes = await Promise.all(tasks);
      const failure = outcomes.find(outcome => !outcome.ok);
      if (failure) throw failure.error;
    }
  };
}
