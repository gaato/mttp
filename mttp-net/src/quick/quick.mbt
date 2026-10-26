///|
let default_client : Ref[@client.Client?] = Ref(None)

///|
fn get_client() -> @client.Client {
  match default_client.val {
    Some(client) => client
    None => {
      let client = @net.new_client()
      default_client.val = Some(client)
      client
    }
  }
}

///|
/// Sends using a lazily created, shared platform backend and clock. The
/// default client follows redirects, has no retries or cookie jar, and uses
/// the ordinary request/body limits. Use Client directly for custom policy.
/// On JS, fetch platform restrictions still apply (including opaque redirects).
pub async fn[T, M : @client.ResponseMode] send(
  request : @client.RequestPlan[T, M],
) -> @client.Reply[T] {
  get_client().send(request)
}

///|
/// Closes the current default backend and forgets it. Existing responses
/// retain their body ownership; a later send creates a fresh default client.
/// Safe before the first send and after a previous close.
pub fn close() -> Unit {
  let client = default_client.val
  default_client.val = None
  if client is Some(client) {
    client.close()
  }
}
