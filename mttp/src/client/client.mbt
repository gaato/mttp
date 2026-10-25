///|
/// A backend plus shared request defaults and injected timing services.
pub struct Client {
  priv backend : &Backend
  priv clock : &@clock.Clock
  priv base_url : String
  priv headers : @model.Headers
  priv options : RequestOptions
  priv timer : &@clock.Timer?
}

///|
/// Creates a client with explicit transport and clock. A timer can enforce
/// deadlines for in-process backends that cannot do so themselves.
pub fn Client::new(
  backend : &Backend,
  clock : &@clock.Clock,
  base_url~ : String = "",
  headers~ : @model.Headers = @model.Headers::empty(),
  options~ : RequestOptions = RequestOptions::default(),
  timer? : &@clock.Timer,
) -> Client {
  { backend, clock, base_url, headers, options, timer, }
}

///|
/// Closes the shared backend. Its close operation is idempotent.
pub fn Client::close(self : Client) -> Unit {
  self.backend.close()
}

///|
fn Client::prepare(
  self : Client,
  request : @model.Request,
) -> @model.Request raise @model.TransportError {
  request.validate()
  let mut headers = @model.Headers::empty()
  for (name, value) in self.headers.iter() {
    if !request.headers.contains(name) {
      headers = headers.add(name, value)
    }
  }
  for (name, value) in request.headers.iter() {
    headers = headers.add(name, value)
  }
  let request = {
    ..request,
    url: @model.join_url(self.base_url, request.url),
    headers,
  }
  request.validate()
  request
}

///|
priv enum ReadResult[T] {
  Buffered(T, @model.Response)
  Streaming(@model.Response, Selected[T])
}

///|
fn timeout(ms : Int32) -> @model.TransportError {
  @model.TransportError(
    kind=Timeout(ms~),
    phase=Unknown,
    detail="attempt deadline expired",
  )
}

///|
async fn[T] Client::exchange(
  self : Client,
  request : @model.Request,
  reader : ResponseAs[T],
  options : RequestOptions,
) -> ReadResult[T] {
  let started = self.clock.now_unix_ms()
  let response = self.backend.send(request, options)
  let mut transferred = false
  defer (if !transferred { response.close() })
  if options.timeout_ms is Some(ms) &&
    self.clock.now_unix_ms() - started >= ms.to_int64() {
    raise timeout(ms)
  }
  let head = response.head()
  let selected = (reader.select)(head)
  if !selected.accept {
    let body = error_excerpt(response.body)
    (selected.reject)(head, body)
    raise UnexpectedStatus(head, body~)
  }
  if selected.streaming {
    transferred = true
    return Streaming(response, selected)
  }
  Buffered((selected.read)(head, response.body, options), response)
}

///|
/// Sends with merged defaults and decodes the response. Accepted streaming
/// callbacks run after the head exchange and own the body until they return.
pub async fn[T] Client::send(
  self : Client,
  request : ClientRequest[T],
) -> Reply[T] {
  let raw = self.prepare(request.raw)
  let options = {
    ..request.options(self.options),
    body_deadline: !request.response_as.streaming,
  }
  if options.timeout_ms is Some(ms) && ms <= 0 {
    raise timeout(ms)
  }
  let raw = match request.body_factory {
    Some(factory) => raw.body_bytes(factory())
    None => raw
  }
  let outcome = match (self.timer, options.timeout_ms) {
    (Some(timer), Some(ms)) => {
      let mut result : Result[ReadResult[T], Error]? = None
      let complete = timer.within(ms, () => {
        result = Some(
          Ok(self.exchange(raw, request.response_as, options)) catch {
            error => Err(error)
          },
        )
      })
      match result {
        Some(Ok(value)) => value
        Some(Err(error)) => raise error
        None if !complete => raise timeout(ms)
        None =>
          raise @model.TransportError(
            kind=Protocol,
            phase=Unknown,
            detail="timer completed without running callback",
          )
      }
    }
    _ => self.exchange(raw, request.response_as, options)
  }
  let (body, response) = match outcome {
    Buffered(body, response) => (body, response)
    Streaming(response, selected) => {
      defer response.close()
      ((selected.read)(response.head(), response.body, options), response)
    }
  }
  {
    status: response.status,
    headers: response.headers,
    body,
    request: raw.head(),
    attributes: response.attributes,
  }
}

///|
/// Pairs a wire request with a UTF-8 string reader accepting successful statuses.
pub fn request(raw : @model.Request) -> ClientRequest[String] {
  ClientRequest::new(raw, as_string())
}

///|
/// Pairs a wire request with a UTF-8 string reader accepting every HTTP status.
pub fn quick_request(raw : @model.Request) -> ClientRequest[String] {
  ClientRequest::new(raw, as_string().any_status())
}
