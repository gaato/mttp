// The HTTP/3 pair's server certificate and key: a copy of
// mttp_ng/testdata/localhost.pem and localhost.key, a test certificate
// with no secret worth keeping. A fuzz target is a plain function, so it
// reads no file; and the pair's client trusts any certificate (`Insecure`),
// so the two need only belong together.

///|
let server_chain : String =
  #|-----BEGIN CERTIFICATE-----
  #|MIIBpzCCAU2gAwIBAgIUao+K82+1nqYlmL7t9PkdwL1JYqwwCgYIKoZIzj0EAwIw
  #|HjEcMBoGA1UEAwwTbXR0cF9jdXJsIHRlc3Qgcm9vdDAeFw0yMDAxMDEwMDAwMDBa
  #|Fw00MDAxMDEwMDAwMDBaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDBZMBMGByqGSM49
  #|AgEGCCqGSM49AwEHA0IABCG4aWT3ZCAviMFZXyjW7BZyJoFDiOFOdGD7TsseEDcL
  #|RViC1fPFlqbMQckn0DSFOl/6hjRhDZQCj0NOPFEVj2SjczBxMBoGA1UdEQQTMBGC
  #|CWxvY2FsaG9zdIcEfwAAATATBgNVHSUEDDAKBggrBgEFBQcDATAdBgNVHQ4EFgQU
  #|tbghvpswWSKG+MBqq0uEMWmAoGQwHwYDVR0jBBgwFoAUla/jvcPl1FswuE4UJw/0
  #|R8dAwNEwCgYIKoZIzj0EAwIDSAAwRQIhAIunMK71dHt8kuUUjmAo7j677j639XrX
  #|5AuIVmiZMPSCAiBluDd2Vijqqsw4eQvGxIqX5BydeLrVmcH1UAUHCiDhuw==
  #|-----END CERTIFICATE-----

///|
let server_key : String =
  #|-----BEGIN PRIVATE KEY-----
  #|MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQggFaIbJm8jm4tAprd
  #|/cCFOmAp4NGpT7+QvF9NdEDPfbKhRANCAAQhuGlk92QgL4jBWV8o1uwWciaBQ4jh
  #|TnRg+07LHhA3C0VYgtXzxZamzEHJJ9A0hTpf+oY0YQ2UAo9DTjxRFY9k
  #|-----END PRIVATE KEY-----
