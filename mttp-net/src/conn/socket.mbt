///|
priv struct IoBridge {
  inner : &@connection.Conn
  buffer : @io.ReaderBuffer
}

///|
impl @io.Reader for IoBridge with fn _get_internal_buffer(self) {
  self.buffer
}

///|
impl @io.Reader for IoBridge with fn _direct_read(self, out, offset~, max_len~) {
  match self.inner.read(max_len~) {
    None => 0
    Some(bytes) => {
      for i in 0..<bytes.length() {
        out[offset + i] = bytes[i]
      }
      bytes.length()
    }
  }
}

///|
impl @io.Writer for IoBridge with fn write_once(self, bytes, offset~, len~) {
  self.inner.write(bytes[offset:offset + len].to_owned())
  len
}

///|
priv struct TlsConn {
  tls : @tls.Tls
  inner : &@connection.Conn
  mut closed : Bool
}

///|
impl @connection.Conn for TlsConn with fn read(self, max_len~) {
  if self.closed {
    return None
  }
  self.tls.read_some(max_len~) catch {
    error => raise transport_error(error)
  }
}

///|
impl @connection.Conn for TlsConn with fn write(self, bytes) {
  if self.closed {
    raise @model.TransportError(
      kind=Network,
      phase=Unknown,
      detail="connection closed",
    )
  }
  self.tls.write(bytes) catch {
    error => raise transport_error(error)
  }
}

///|
impl @connection.Conn for TlsConn with fn close(self) {
  if !self.closed {
    self.closed = true
    self.tls.close()
    self.inner.close()
  }
}

///|
fn transport_error(error : Error) -> @model.TransportError {
  match error {
    @model.TransportError(..) as error => error
    _ =>
      @model.TransportError(
        kind=Network,
        phase=Unknown,
        detail=error.to_string(),
      )
  }
}

///|
/// TCP plus verified TLS. A custom CA file replaces the system root set.
pub struct TcpDialer {
  priv ca_file : String?
}

///|
/// Uses system TLS roots unless a custom CA file is supplied.
pub fn TcpDialer::new(ca_file? : String) -> TcpDialer {
  { ca_file, }
}

///|
/// Makes the portable dialer operations available as methods.
pub extend TcpDialer with @connection.Dialer::{connect, start_tls}

///|
/// Dials TCP and reports connection failures in the Dial phase.
pub impl @connection.Dialer for TcpDialer with fn connect(_, host~, port~) {
  let tcp = @socket.Tcp::connect_to_host(host, port~) catch {
    error =>
      raise @model.TransportError(
        kind=Connect,
        phase=Dial,
        detail=error.to_string(),
      )
  }
  @socket_conn.from_tcp(tcp)
}

///|
/// Verifies TLS for host; success owns inner, failure leaves caller ownership.
pub impl @connection.Dialer for TcpDialer with fn start_tls(self, inner, host~) {
  let bridge = IoBridge::{ inner, buffer: @io.ReaderBuffer::new(), }
  let tls = @tls.Tls::client(
    bridge,
    host~,
    trust=match self.ca_file {
      Some(path) => CustomPemFile(path)
      None => SystemRoot
    },
  ) catch {
    error =>
      raise @model.TransportError(
        kind=Connect,
        phase=Dial,
        detail=error.to_string(),
      )
  }
  TlsConn::{ tls, inner, closed: false, }
}
