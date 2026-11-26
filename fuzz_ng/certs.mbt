// The HTTP/3 pair's server certificate and key: a copy of
// mttp_ng/testdata/localhost.pem and localhost.key, a test certificate
// with no secret worth keeping. A fuzz target is a plain function, so it
// reads no file; and the pair's client trusts any certificate (`Insecure`),
// so the two need only belong together.

///|
let server_chain : String =
  #|-----BEGIN CERTIFICATE-----
  #|MIIBpTCCAUugAwIBAgIUeOXNPdJM+pQIKyXdsWeTMaU7F1QwCgYIKoZIzj0EAwIw
  #|HDEaMBgGA1UEAwwRbXR0cF9uZyB0ZXN0IHJvb3QwHhcNMjAwMTAxMDAwMDAwWhcN
  #|NDAwMTAxMDAwMDAwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIB
  #|BggqhkjOPQMBBwNCAAQ//eMX7Wlx2HPtAcM3i0zb1t/mExmoZh3aKurjqfwZuphr
  #|mslqJEjM18YM11Jbc6bIMeh2qzqUMraOp0xY2u5co3MwcTAaBgNVHREEEzARggls
  #|b2NhbGhvc3SHBH8AAAEwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYDVR0OBBYEFP9X
  #|nM+kVJTBCjc5uOnm9tUjEV2tMB8GA1UdIwQYMBaAFCDYjfgqOpO5RHP8FUSbWGCP
  #|QWFYMAoGCCqGSM49BAMCA0gAMEUCIErNi6qzdEjrFZCN7i+X6/NOX6Yz9PKK0LT2
  #|vvFjmgZ+AiEA8ezkdc96Morxb1L6s1kj8EYneA5QrxxqhKmsTBPVL7M=
  #|-----END CERTIFICATE-----

///|
let server_key : String =
  #|-----BEGIN PRIVATE KEY-----
  #|MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyOPq5iBmPxI3GE4h
  #|bo4w35YTTqf0aJT7vfhhQrg9kuyhRANCAAQ//eMX7Wlx2HPtAcM3i0zb1t/mExmo
  #|Zh3aKurjqfwZuphrmslqJEjM18YM11Jbc6bIMeh2qzqUMraOp0xY2u5c
  #|-----END PRIVATE KEY-----
