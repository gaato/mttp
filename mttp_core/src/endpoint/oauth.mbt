///|
/// An OAuth2 flow with its required URLs and advertised scope descriptions.
/// DeviceAuthorization can only be projected to OpenAPI 3.2.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum OAuthFlow {
  AuthorizationCode(
    authorization_url~ : String,
    token_url~ : String,
    refresh_url~ : String?,
    scopes~ : Map[String, String],
  )
  ClientCredentials(
    token_url~ : String,
    refresh_url~ : String?,
    scopes~ : Map[String, String],
  )
  Implicit(
    authorization_url~ : String,
    refresh_url~ : String?,
    scopes~ : Map[String, String],
  )
  Password(
    token_url~ : String,
    refresh_url~ : String?,
    scopes~ : Map[String, String],
  )
  DeviceAuthorization(
    device_authorization_url~ : String,
    token_url~ : String,
    refresh_url~ : String?,
    scopes~ : Map[String, String],
  )
}

///|
/// Compares OAuth flow declarations.
pub extend OAuthFlow with Eq::{equal, not_equal}

///|
/// Formats OAuth flow declarations.
pub extend OAuthFlow with @debug.Debug::{to_repr}

///|
/// Reads and writes a Bearer token and declares its OAuth2 flows and required
/// scopes. Does not validate the token or its scopes; the application must do so.
pub fn oauth2(
  flows~ : Array[OAuthFlow],
  scopes~ : Array[String] = [],
  scheme_name~ : String = "oauth2",
) -> Input[String] {
  bearer_input(OAuth2(flows~, scopes~), scheme_name)
}

///|
/// Reads and writes a Bearer token and declares an OpenID Connect discovery
/// URL and required scopes. Does not validate the token or its scopes; the
/// application must do so.
pub fn openid_connect(
  url : String,
  scopes~ : Array[String] = [],
  scheme_name~ : String = "openIdConnect",
) -> Input[String] {
  bearer_input(OpenIdConnect(url~, scopes~), scheme_name)
}

///|
fn OAuthFlow::kind(self : OAuthFlow) -> String {
  match self {
    AuthorizationCode(..) => "authorizationCode"
    ClientCredentials(..) => "clientCredentials"
    Implicit(..) => "implicit"
    Password(..) => "password"
    DeviceAuthorization(..) => "deviceAuthorization"
  }
}

///|
fn OAuthFlow::scopes(self : OAuthFlow) -> Map[String, String] {
  match self {
    AuthorizationCode(scopes~, ..)
    | ClientCredentials(scopes~, ..)
    | Implicit(scopes~, ..)
    | Password(scopes~, ..)
    | DeviceAuthorization(scopes~, ..) => scopes
  }
}

///|
fn check_oauth(
  atom : Atom,
  template : String,
  out : Array[DefinitionProblem],
) -> Unit {
  guard atom.location is Auth(scheme=OAuth2(flows~, scopes~), scheme_name~) else {
    return
  }
  if flows.is_empty() {
    out.push(
      DefinitionProblem::new(
        template,
        "OAuth2 scheme " + scheme_name + " has no flows",
      ),
    )
  }
  let kinds : Map[String, Bool] = Map([])
  for flow in flows {
    let kind = flow.kind()
    if kinds.contains(kind) {
      out.push(
        DefinitionProblem::new(
          template,
          "OAuth2 scheme " + scheme_name + " repeats flow " + kind,
        ),
      )
    }
    kinds[kind] = true
  }
  for scope in scopes {
    if !flows.iter().any(flow => flow.scopes().contains(scope)) {
      out.push(
        DefinitionProblem::new(
          template,
          "OAuth2 scheme " + scheme_name + " requires undeclared scope " + scope,
        ),
      )
    }
  }
}
