///|
/// The server: serve with authenticate + handle. Constructors are
/// qualified outside the defining package (I-06).
pub fn app(
  store : Map[Int, @api.User],
  unhandled : Array[String],
  middleware? : Array[@router.Middleware] = [],
) -> @router.Router raise @endpoint.DefinitionError {
  let auth = async fn(token : String) -> String { if token == "secret" { "admin" } else { raise @api.Forbidden } }
  @router.Router::new(
    [
      @api.get_user.serve(auth, async fn(_who, q) {
        if q.id == 500 {
          raise Failure("database is down") // unclassified -> 500
        }
        match store.get(q.id) {
          Some(u) => u
          None => raise @api.NotFound(q.id)
        }
      }),
      @api.get_team.serve(auth, async fn(_who, name) {
        if name == "core" {
          { name, lead: store.get(1).unwrap() }
        } else {
          raise @api.NoTeam(name)
        }
      }),
      @api.create_user.serve(auth, async fn(_who, n) {
        let id = store.length() + 1
        let u : @api.User = { id, name: n.name }
        store[id] = u
        (u, "/api/v1/users/\{id}")
      }),
      @api.user_events.serve_public(async fn(_) {
        @endpoint.EventStream::from_array(store.values().collect())
      }),
      @api.whoami.serve_public(async fn(addr) {
        { label: addr.unwrap_or("?"), children: [{ label: "leaf", children: [] }] }
      }),
      @api.webhook.serve(
        async fn(sig_body) {
          let (sig, body) = sig_body
          if sig != "len=\{body.length()}" {
            raise @api.Forbidden
          }
        },
        async fn(_, _n) { () },
      ),
    ],
    options={
      ..@router.ServerOptions::default(),
      on_unhandled: (_req, e) => {
        unhandled.push(e.to_string())
        None
      },
      middleware,
    },
  )
}

///|
pub fn store() -> Map[Int, @api.User] {
  Map::from_array([(1, { id: 1, name: "gaato" })])
}

///|
/// A client over any backend (the Router itself in these tests).
pub fn client(backend : &@client.Backend, clock? : @fake.FakeClock = @fake.FakeClock::new(), retry? : &@client.RetryDecider) -> @client.Client {
  @client.Client::new(backend, clock, base_url="http://in-process", retry?, random=() => 0.0)
}

///|
pub async fn client_usage(c : @client.Client) -> String {
  let user = @api.get_user.call(c, "secret", { id: 1, fields: None }) catch {
    @api.NotFound(_) => return "none"
    e => raise e
  }
  user.name
}
