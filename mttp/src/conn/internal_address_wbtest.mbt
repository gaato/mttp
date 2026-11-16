///|
test "internal address policy covers IPv4 IPv6 mapped forms and prefix edges" {
  let denied = [
    "0.0.0.0", "0.255.255.255", "10.0.0.0", "10.255.255.255", "100.64.0.0", "100.127.255.255",
    "127.0.0.1", "169.254.0.0", "169.254.255.255", "172.16.0.0", "172.31.255.255",
    "192.168.0.0", "192.168.255.255", "192.0.0.1", "192.0.2.1", "192.88.99.1", "198.18.0.0",
    "198.19.255.255", "198.51.100.1", "203.0.113.1", "224.0.0.0", "239.255.255.255",
    "240.0.0.0", "255.255.255.255",
  ]
  for host in denied {
    assert_true(internal_address(@socket.Addr::parse(host + ":80")), msg=host)
    assert_true(
      internal_address(@socket.Addr::parse("[::ffff:" + host + "]:80")),
      msg=host,
    )
  }
  for
    host in [
      "1.0.0.0", "9.255.255.255", "11.0.0.0", "100.63.255.255", "100.128.0.0", "169.253.255.255",
      "169.255.0.0", "172.15.255.255", "172.32.0.0", "192.167.255.255", "192.169.0.0",
      "198.17.255.255", "198.20.0.0", "223.255.255.255", "8.8.8.8",
    ] {
    assert_false(internal_address(@socket.Addr::parse(host + ":80")), msg=host)
    assert_false(
      internal_address(@socket.Addr::parse("[::ffff:" + host + "]:80")),
      msg=host,
    )
  }
  for
    host in [
      "::", "::1", "::127.0.0.1", "::ffff:7f00:1", "fc00::", "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
      "fe80::", "febf:ffff::", "fec0::1", "ffff::", "64:ff9b::7f00:1", "64:ff9b:1::1",
      "100::1", "100:0:0:1::1", "2001::1", "2001:1ff::1", "2001:db8::1", "2002:7f00:1::",
      "3fff:fff::1", "5f00::1",
    ] {
    assert_true(
      internal_address(@socket.Addr::parse("[" + host + "]:80")),
      msg=host,
    )
  }
  for
    host in [
      "2001:200::1", "2001:4860:4860::8888", "2606:4700:4700::1111", "3fff:1000::1",
      "4000::1", "fbff::1", "fe7f:ffff::1",
    ] {
    assert_false(
      internal_address(@socket.Addr::parse("[" + host + "]:80")),
      msg=host,
    )
  }
}
