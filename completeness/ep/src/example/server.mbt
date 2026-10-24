///|
/// Server logic: implementation package (server only).
pub fn app(store : Map[Int, User]) -> @endpoint.Server raise @endpoint.RouteError {
  let authenticate = async fn(token : String) -> String {
    if token == "secret" {
      "admin"
    } else {
      raise Forbidden
    }
  }
  @endpoint.Server::new([
    get_user.serve(authenticate, async fn(_who, input) {
      match store.get(input.id) {
        Some(u) => u
        None => raise NotFound(input.id)
      }
    }),
    create_user.serve(authenticate, async fn(_who, nu) {
      let id = store.length() + 1
      let u = { id, name: nu.name }
      store[id] = u
      u
    }),
    webhook.serve(
      async fn(sig) {
        let (signature, raw) = sig
        // stands in for Ed25519/HMAC over the exact bytes received
        if signature != "len=\{raw.length()}" {
          raise Forbidden
        }
      },
      async fn(_, _) { () },
    ),
    echo_ws.serve(authenticate, async fn(_who, _, ch) {
      while (ch.recv)() is Some(u) {
        (ch.send)({ ..u, name: u.name.to_upper() })
      }
    }),
    user_events.serve_public(async fn(_) {
      let users = store.values().collect()
      let mut i = 0
      {
        next: async fn() {
          if i < users.length() {
            i += 1
            Some(users[i - 1])
          } else {
            None
          }
        },
        close: () => (),
      }
    }),
  ])
}

///|
pub fn spec(server : @endpoint.Server) -> Json {
  @openapi.document(server.docs(), title="users", version="1.0.0")
}

///|
/// Typed client, raising the declared error.
pub async fn fetch_name(backend : &@client.Backend, id : Int) -> String {
  let base = @model.Uri::relative([])
  let user = get_user.call(backend, base, "secret", { id, fields: None }) catch {
    NotFound(_) => return "<none>"
    e => raise e
  }
  user.name
}

///|
/// Plain client, sttp style.
pub async fn plain(backend : &@client.Backend) -> String {
  let id = 1
  let uri = @model.UriBuilder::new()
  uri <+ "/users/\{id}"
  ignore(uri.raw())
  let resp = @client.basic_request
    .get(@model.Uri::relative(["users", id.to_string()]))
    .header("authorization", "Bearer secret")
    .send(backend)
  match resp.body {
    Ok(s) => s
    Err(s) => "error: \{s}"
  }
}
