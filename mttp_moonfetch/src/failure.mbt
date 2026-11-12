// moonfetch's failures as mttp's TransportError. The phase matters most:
// mttp's Client resends any request whose failure proves it was never sent
// (`TransportError::is_unsent`: phase Pool or Dial, or kind Connect or
// Proxy), but resends a request that may have been sent only when it is
// idempotent. moonfetch does not say how far an exchange got, so a failure
// counts as unsent only when its kind can only happen before the request is
// written: resolving the host, connecting, the TLS handshake, the proxy, or
// a stream the server refused before processing it. Anything else is
// reported in phase Unknown (or Body), which mttp treats as possibly sent.

///|
/// `failure(e, phase)` classifies `e`; `phase` is the phase of a failure
/// that could have happened after the request was written.
fn failure(e : Error, phase : @mttp.Phase) -> @mttp.TransportError {
  let detail = @debug.to_string(e)
  match e {
    @mttp.TransportError(_) as error => error
    @moonfetch.Url(_) => @mttp.TransportError(kind=Invalid, phase=Pool, detail~)
    @moonfetch.Proxy(message) =>
      @mttp.TransportError(
        kind=Proxy(status=proxy_status(message)),
        phase=Dial,
        detail~,
      )
    // REFUSED_STREAM (RFC 9113 §8.7), raised by moonfetch both for a stream
    // it would not open on a connection that was closing and for one the
    // server refused or left past its GOAWAY: either way the server did not
    // process the request, so it may be sent again whatever its method.
    @moonfetch.Reset(code~) if code == refused_stream =>
      @mttp.TransportError(
        kind=Network,
        phase=Pool,
        detail="refused before processing: \{detail}",
      )
    @moonfetch.Reset(_) => @mttp.TransportError(kind=Network, phase~, detail~)
    @moonfetch.Timeout(limit~) =>
      @mttp.TransportError(kind=Timeout(ms=limit), phase~, detail~)
    @moonfetch.Exceeded(limit~, ..) =>
      @mttp.TransportError(kind=TooLarge(limit~), phase~, detail~)
    @socket.ResolveHostnameError(_) | @socket.InvalidAddr =>
      @mttp.TransportError(kind=Connect, phase=Dial, detail~)
    @os_error.OSError(_, context~) if is_connect(context) =>
      @mttp.TransportError(kind=Connect, phase=Dial, detail~)
    @alert.Alert(kind~, ..) if handshake_only(kind) =>
      @mttp.TransportError(kind=Connect, phase=Dial, detail~)
    // The peer closed the connection early: moonhttp reports a close before
    // the head as a malformed message, and says so in its text.
    @http1.Partial | @http2.Incomplete =>
      @mttp.TransportError(kind=Network, phase~, detail~)
    @http1.Malformed(why) if why.contains("closed") =>
      @mttp.TransportError(kind=Network, phase~, detail~)
    // RFC 9114 §8.1 H3_REQUEST_REJECTED: rejected without any processing.
    @http3.Fault(code=RequestRejected, ..) =>
      @mttp.TransportError(
        kind=Network,
        phase=Pool,
        detail="refused before processing: \{detail}",
      )
    @http1.Malformed(_)
    | @http1.Smuggled(_)
    | @http1.Order(_)
    | @http1.Version(_)
    | @http1.Coding(_)
    | @http1.Exceeded(..)
    | @http2.FrameSizeError(_)
    | @http2.ProtocolError(_)
    | @http2.Connection(_, ..)
    | @http2.Order(_)
    | @http3.Malformed(_)
    | @http3.Fault(..) => @mttp.TransportError(kind=Protocol, phase~, detail~)
    _ => @mttp.TransportError(kind=Network, phase~, detail~)
  }
}

///|
/// RFC 9113 §7 REFUSED_STREAM, the code moonfetch uses for HTTP/3 as well.
let refused_stream : Int32 = 7

///|
/// Whether an OSError comes from opening a socket rather than using one.
fn is_connect(context : String) -> Bool {
  context.contains("connect")
}

///|
/// The status of a proxy's refused CONNECT (moonfetch says "CONNECT
/// answered 407"), or 0 when the proxy failed some other way.
fn proxy_status(message : String) -> Int32 {
  guard message.find("CONNECT answered ") is Some(at) else { return 0 }
  let digits = message[at + 17:]
  let mut status = 0
  for c in digits {
    guard c >= '0' && c <= '9' else { break }
    status = status * 10 + (c.to_int() - '0'.to_int())
  }
  status
}

///|
/// TLS alerts that only a handshake raises: certificate and negotiation
/// failures. An alert on an established connection (a bad record, a close)
/// can arrive after the request was written and is not one of these.
fn handshake_only(kind : @alert.Kind) -> Bool {
  kind
  is (HandshakeFailure
  | BadCertificate
  | UnsupportedCertificate
  | CertificateRevoked
  | CertificateExpired
  | CertificateUnknown
  | UnknownCa
  | ProtocolVersion
  | InsufficientSecurity
  | InappropriateFallback
  | MissingExtension
  | UnsupportedExtension
  | UnrecognizedName
  | BadCertificateStatusResponse
  | UnknownPskIdentity
  | NoApplicationProtocol)
}
