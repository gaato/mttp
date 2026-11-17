// Conservative destination policy derived from RFC 6890 and the IANA
// IPv4/IPv6 Special-Purpose Address Registries (consulted 2026-11-16):
// https://www.iana.org/assignments/iana-ipv4-special-registry/
// https://www.iana.org/assignments/iana-ipv6-special-registry/
// Deny selected private/local, documentation, benchmarking, transition and reserved
// blocks. Entire protocol-assignment blocks are denied, including their
// globally reachable anycast exceptions; this is an opt-in conservative guard.

///|
fn internal_v4(b : ArrayView[Int32]) -> Bool {
  b[0] == 0 ||
  b[0] == 10 ||
  b[0] == 127 ||
  (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
  (b[0] == 169 && b[1] == 254) ||
  (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
  (
    b[0] == 192 &&
    (
      (b[1] == 0 && (b[2] == 0 || b[2] == 2)) ||
      (b[1] == 88 && b[2] == 99) ||
      b[1] == 168
    )
  ) ||
  (b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) ||
  (b[0] == 203 && b[1] == 0 && b[2] == 113) ||
  b[0] >= 224
}

///|
/// Bytes in network order, as exposed by core/async's numeric address.
fn address_bytes(addr : @socket.Addr) -> Array[Int32] {
  match addr.ip {
    Ipv4(ip) =>
      [
        (ip >> 24).reinterpret_as_int(),
        ((ip >> 16) & 255).reinterpret_as_int(),
        ((ip >> 8) & 255).reinterpret_as_int(),
        (ip & 255).reinterpret_as_int(),
      ]
    Ipv6(bytes, ..) => bytes.iter().map(b => b.to_int()).to_array()
  }
}

///|
fn internal_address(addr : @socket.Addr) -> Bool {
  let b = address_bytes(addr)
  if b.length() == 4 {
    return internal_v4(b)
  }
  if b[:10].iter().all(x => x == 0) && b[10] == 255 && b[11] == 255 {
    return internal_v4(b[12:])
  }
  b[:12].iter().all(x => x == 0) || // unspecified, loopback, obsolete IPv4-compatible
  (
    b[0] == 0 &&
    b[1] == 0x64 &&
    b[2] == 0xff &&
    b[3] == 0x9b &&
    b[4] == 0 &&
    (b[5] == 1 || (b[5] == 0 && b[6:12].iter().all(x => x == 0)))
  ) || // NAT64
  (b[0] == 1 && b[1:7].iter().all(x => x == 0) && b[7] <= 1) || // discard/dummy
  (b[0] == 0x20 && b[1] == 1 && b[2] < 2) || // protocol assignments /23
  (b[0] == 0x20 && b[1] == 1 && b[2] == 0x0d && b[3] == 0xb8) ||
  (b[0] == 0x20 && b[1] == 2) || // 6to4
  (b[0] == 0x3f && b[1] == 0xff && b[2] < 16) ||
  (b[0] == 0x5f && b[1] == 0) ||
  (b[0] & 0xfe) == 0xfc ||
  (b[0] == 0xfe && b[1] >= 0x80) || // link-local and deprecated site-local
  b[0] == 0xff
}
