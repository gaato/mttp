This self-signed localhost certificate and private key are public test fixtures.
They are used only by the loopback TLS test, which checks both explicit local
trust and rejection by the backend's system trust roots. They are not deployment
credentials.

Generated with OpenSSL for `localhost` and `127.0.0.1`, with a 100-year lifetime
to avoid ordinary test failures caused by fixture expiration.
