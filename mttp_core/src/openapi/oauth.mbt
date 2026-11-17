///|
fn add_scopes(
  requirement : Map[String, Array[String]],
  name : String,
  scopes : Array[String],
) -> Unit {
  let combined = requirement.get(name).unwrap_or([])
  for scope in scopes {
    if !combined.contains(scope) {
      combined.push(scope)
    }
  }
  combined.sort_by((a, b) => a[:].lexical_compare(b[:]))
  requirement[name] = combined
}

///|
fn oauth_flows(
  flows : Array[@endpoint.OAuthFlow],
  version : OpenApiVersion,
  scheme_name : String,
  template : String,
  problems : Array[@endpoint.DefinitionProblem],
) -> @apispec.OAuthFlows {
  let mut result = @apispec.OAuthFlows::new()
  for flow in flows {
    result = match flow {
      AuthorizationCode(authorization_url~, token_url~, refresh_url~, scopes~) =>
        {
          ..result,
          authorization_code: Some(
            @apispec.OAuthFlowObject::new(
              scopes.copy(),
              authorization_url~,
              token_url~,
              refresh_url?,
            ),
          ),
        }
      ClientCredentials(token_url~, refresh_url~, scopes~) =>
        {
          ..result,
          client_credentials: Some(
            @apispec.OAuthFlowObject::new(
              scopes.copy(),
              token_url~,
              refresh_url?,
            ),
          ),
        }
      Implicit(authorization_url~, refresh_url~, scopes~) =>
        {
          ..result,
          implicit: Some(
            @apispec.OAuthFlowObject::new(
              scopes.copy(),
              authorization_url~,
              refresh_url?,
            ),
          ),
        }
      Password(token_url~, refresh_url~, scopes~) =>
        {
          ..result,
          password: Some(
            @apispec.OAuthFlowObject::new(
              scopes.copy(),
              token_url~,
              refresh_url?,
            ),
          ),
        }
      DeviceAuthorization(
        device_authorization_url~,
        token_url~,
        refresh_url~,
        scopes~,
      ) => {
        if version is V3_1 {
          problems.push(
            @endpoint.DefinitionProblem::new(
              template,
              "OAuth2 scheme " +
              scheme_name +
              " uses deviceAuthorization which requires OpenAPI 3.2",
            ),
          )
        }
        {
          ..result,
          device_authorization: Some(
            @apispec.OAuthFlowObject::new(
              scopes.copy(),
              device_authorization_url~,
              token_url~,
              refresh_url?,
            ),
          ),
        }
      }
      @endpoint.OAuthFlow::.. => {
        problems.push(
          @endpoint.DefinitionProblem::new(
            template,
            "unsupported OAuth2 flow in scheme " + scheme_name,
          ),
        )
        result
      }
    }
  }
  result
}
