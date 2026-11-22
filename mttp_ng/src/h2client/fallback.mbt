// HTTP/1.1 where HTTP/2 is not spoken: cleartext URLs without h2c, and
// origins whose server chose http/1.1 (or nothing) by ALPN. Those requests
// go to gaato/mttp_core's HTTP/1 client, over a dialer that hands it the
// TLS connection the HTTP/2 dial already opened, so the server sees one
// connection, not two.

///|
/// The dialer of the HTTP/1 client. `connect` returns a connection parked
/// for that host and port when there is one, already over TLS, and
/// `start_tls` then returns it as it is; otherwise TCP comes from the
/// backend's dialer and TLS is this package's, offering http/1.1 only.
priv struct HandoffDialer {
  tcp : &@rt.Dialer
  tls : @tls.ClientTls
  coordination : &@rt.Coordination
  /// TLS connections the HTTP/2 dial opened and the server gave http/1.1,
  /// waiting for the HTTP/1 client's next dial to the same host and port.
  parked : Array[(String, Int32, &@rt.Conn)]
  /// The parked connections `connect` handed out, which `start_tls`
  /// returns unchanged.
  handed : Array[&@rt.Conn]
}

///|
fn HandoffDialer::park(
  self : HandoffDialer,
  host : String,
  port : Int32,
  conn : &@rt.Conn,
) -> Unit {
  self.parked.push((host, port, conn))
}

///|
/// Closes the connections no dial took.
fn HandoffDialer::close(self : HandoffDialer) -> Unit {
  for entry in self.parked {
    entry.2.close()
  }
  self.parked.clear()
  for conn in self.handed {
    conn.close()
  }
  self.handed.clear()
}

///|
impl @rt.Dialer for HandoffDialer with fn connect(self, host~, port~) {
  match self.parked.search_by(entry => entry.0 == host && entry.1 == port) {
    Some(i) => {
      let (_, _, conn) = self.parked.remove(i)
      self.handed.push(conn)
      conn
    }
    None => self.tcp.connect(host~, port~)
  }
}

///|
impl @rt.Dialer for HandoffDialer with fn start_tls(self, conn, host~) {
  match self.handed.search_by(handed => physical_equal(handed, conn)) {
    Some(i) => {
      ignore(self.handed.remove(i))
      conn
    }
    None => self.tls.connect(conn, host~, coordination=self.coordination)
  }
}

///|
/// How long an origin whose server chose http/1.1 is sent HTTP/1.1 without
/// asking again.
const HTTP11_TTL_MS : Int64 = 600000L

///|
/// At most this many origins are remembered as HTTP/1.1; the oldest goes
/// first.
const HTTP11_ORIGINS : Int32 = 256

///|
/// Remembers `origin` as one that speaks HTTP/1.1 only.
fn H2Backend::remember_http11(self : H2Backend, origin : String) -> Unit {
  let now = self.clock.now_unix_ms()
  if !self.http11.contains(origin) && self.http11.length() >= HTTP11_ORIGINS {
    let mut oldest : (String, Int64)? = None
    for key, until in self.http11 {
      if oldest is None || until < oldest.unwrap().1 {
        oldest = Some((key, until))
      }
    }
    if oldest is Some((key, _)) {
      self.http11.remove(key)
    }
  }
  self.http11[origin] = now + HTTP11_TTL_MS
}

///|
/// Whether `origin` was found to speak HTTP/1.1 only, not long ago.
fn H2Backend::speaks_http11(self : H2Backend, origin : String) -> Bool {
  match self.http11.get(origin) {
    Some(until) if until > self.clock.now_unix_ms() => true
    Some(_) => {
      self.http11.remove(origin)
      false
    }
    None => false
  }
}

///|
/// `request` for the HTTP/1 client after this send dialled for it: the time
/// already spent comes off the deadline, and the `Dialed` and `TlsDone` the
/// HTTP/1 client reports again for the connection it is handed are left
/// out, since this send reported them (rule 13: each at most once).
fn handed_over(
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
  timer : @attempt.AttemptTimer,
) -> (@mttp_core.Request, @mttp_core.SendOptions) {
  let options = match timer.remaining() {
    Some(ms) =>
      { ..options, timeout_ms: Some(if ms < 1L { 1 } else { ms.to_int() }), }
    None => options
  }
  let request = match request.attributes.get(@mttp_core.on_phase) {
    Some(report) =>
      request.attribute(@mttp_core.on_phase, event => {
        match event {
          Dialed(..) | TlsDone => ()
          _ => report(event)
        }
      })
    None => request
  }
  (request, options)
}
