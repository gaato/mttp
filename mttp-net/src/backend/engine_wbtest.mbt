///|
using @engine {
  type PhaseTimer,
  type ResponseBody,
  type Ticket,
  type ProxyServer,
  target,
  configure_proxies,
  parse_proxy,
  parse_no_proxy,
  bypasses_proxy,
  phase_budget,
  open_tunnel,
}

///|
fn phase_exchange(clock : &@clock.Clock, limits : Timeouts) -> PhaseTimer {
  PhaseTimer::exchange(clock, limits, timer=@runtime.ClockTimer::new(clock~))
}

///|
fn phase_stream(clock : &@clock.Clock, limits : Timeouts) -> PhaseTimer {
  PhaseTimer::stream(clock, limits, timer=@runtime.ClockTimer::new(clock~))
}

///|
fn slots_new(max_total? : Int32, max_per_origin? : Int32) -> Slots {
  Slots::new(
    coordination=@runtime.RuntimeCoordination::new(),
    max_total?,
    max_per_origin?,
  )
}

///|
async fn dial_wire(host : String, port : Int32, secure : Bool) -> Wire {
  Wire::dial(@socket_conn.TcpDialer::new(), host, port, secure)
}

///|
async fn duplex(
  wire : Wire,
  body : @model.Body,
  stream : &@model.BodyStream?,
  first : Bytes?,
  framing : @h1.Framing,
  timer : PhaseTimer,
  limits : @h1.Limits,
) -> (@h1.Version, @model.ResponseHead, Bool) raise @model.TransportError {
  @engine.duplex(
    wire,
    body,
    stream,
    first,
    framing,
    timer,
    limits,
    @runtime.RuntimeCoordination::new(),
  )
}
