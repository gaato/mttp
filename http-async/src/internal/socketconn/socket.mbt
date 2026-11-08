///|
priv struct SocketConn[R, W] {
  reader : R
  writer : W
  close_ : () -> Unit
  mut closed : Bool
  mut eof : Bool
  mut pending : Bytes
  mut cancel_read : (() -> Unit)?
  mut cancel_write : (() -> Unit)?
}

///|
impl[R : @io.BinaryReader, W : @io.BinaryWriter] @rt.Conn for SocketConn[R, W] with fn read(
  self,
  max_len~,
) {
  if max_len <= 0 {
    raise @http.TransportError(
      kind=Invalid,
      phase=Unknown,
      detail="max_len must be positive",
    )
  }
  if self.closed || (self.eof && self.pending.is_empty()) {
    return None
  }
  if !self.pending.is_empty() {
    return Some(self.take_pending(max_len))
  }
  let buffer = FixedArray::make(max_len.min(65536), b'\x00')
  // core's handle close can detach an outstanding read without waking it.
  // Keep a structured child per direction so close can request cancellation,
  // while this operation joins cleanup before another operation may start.
  @async.with_task_group(group => {
    let task = group.spawn(
      () => {
        let n = self.reader.read_into(buffer)
        // Commit consumed bytes in the child before waking its waiter. A
        // cancelled read-ahead waiter must not discard the next request.
        if n == 0 {
          self.eof = true
        } else {
          self.pending = Bytes::from_array(buffer[:n])
        }
      },
      allow_failure=true,
    )
    self.cancel_read = Some(() => task.cancel())
    defer {
      self.cancel_read = None
    }
    if self.closed {
      task.cancel()
    }
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled if self.closed => ()
      error => raise error
    }
  }) catch {
    error => raise transport_error(error)
  }
  if self.closed || self.pending.is_empty() {
    None
  } else {
    Some(self.take_pending(max_len))
  }
}

///|
fn[R, W] SocketConn::take_pending(
  self : SocketConn[R, W],
  max_len : Int32,
) -> Bytes {
  let n = self.pending.length().min(max_len)
  let bytes = self.pending[:n].to_owned()
  self.pending = self.pending[n:].to_owned()
  bytes
}

///|
impl[R : @io.BinaryReader, W : @io.BinaryWriter] @rt.Conn for SocketConn[R, W] with fn write(
  self,
  bytes,
) {
  if self.closed {
    raise @http.TransportError(
      kind=Closed,
      phase=Unknown,
      detail="connection closed",
    )
  }
  @async.with_task_group(group => {
    let task = group.spawn(
      () => {
        let mut offset = 0
        while offset < bytes.length() {
          let end = offset + (bytes.length() - offset).min(65536)
          self.writer.write(bytes[offset:end])
          offset = end
        }
      },
      allow_failure=true,
    )
    self.cancel_write = Some(() => task.cancel())
    defer {
      self.cancel_write = None
    }
    if self.closed {
      task.cancel()
    }
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled if self.closed =>
        raise @http.TransportError(
          kind=Closed,
          phase=Unknown,
          detail="connection closed during write",
        )
      error => raise error
    }
  }) catch {
    error => raise transport_error(error)
  }
}

///|
impl[R : @io.BinaryReader, W : @io.BinaryWriter] @rt.Conn for SocketConn[R, W] with fn close(
  self,
) {
  if !self.closed {
    self.closed = true
    self.pending = b""
    if self.cancel_read is Some(cancel) {
      cancel()
    }
    if self.cancel_write is Some(cancel) {
      cancel()
    }
    (self.close_)()
  }
}

///|
pub fn transport_error(error : Error) -> @http.TransportError {
  match error {
    @http.TransportError(..) as original => original
    _ =>
      @http.TransportError(
        kind=Network,
        phase=Unknown,
        detail=error.to_string(),
      )
  }
}

///|
/// Accepted sockets cross the runtime boundary only inside http-async.
pub fn from_tcp(tcp : @socket.Tcp) -> &@rt.Conn {
  SocketConn::{
    reader: tcp,
    writer: tcp,
    close_: () => tcp.close(),
    closed: false,
    eof: false,
    pending: b"",
    cancel_read: None,
    cancel_write: None,
  }
}

///|
/// Successful TLS owns both the TLS session and the underlying tunnel.
pub fn from_tls(tls : @tls.Tls, inner : &@rt.Conn) -> &@rt.Conn {
  SocketConn::{
    reader: tls,
    writer: tls,
    close_: () => {
      tls.close()
      inner.close()
    },
    closed: false,
    eof: false,
    pending: b"",
    cancel_read: None,
    cancel_write: None,
  }
}
