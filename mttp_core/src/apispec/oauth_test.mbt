///|
test "each modeled OAuth flow round trips with extensions and unknown flows" {
  let object_ = @apispec.OAuthFlowObject::new(
    { "read": "Read", "write": "Write" },
    authorization_url="https://id.test/auth",
    token_url="https://id.test/token",
    refresh_url="https://id.test/refresh",
    device_authorization_url="https://id.test/device",
    extensions={ "x-flow": true },
    unmodeled={ "futureField": [1, 2] },
  )
  let flows = @apispec.OAuthFlows::new(
    implicit=object_,
    password=object_,
    client_credentials=object_,
    authorization_code=object_,
    device_authorization=object_,
    extensions={ "x-flows": 1 },
    unmodeled={ "futureFlow": { "anything": true } },
  )
  let scheme = @apispec.SecurityScheme::new("oauth2", flows~, extensions={
    "x-scheme": "retained",
  })
  let decoded : @apispec.SecurityScheme = @json.from_json(Json(scheme))
  assert_eq(decoded, scheme)
  assert_eq(decoded.flows.unwrap().unmodeled, {
    "futureFlow": { "anything": true },
  })
  for
    key in [
      "implicit", "password", "clientCredentials", "authorizationCode", "deviceAuthorization",
    ] {
    let json : Json = {
      "type": "oauth2",
      "flows": Json::object(
        Map::from_array([
          (key, Json(object_)),
          ("x-flows", Json::null()),
          ("futureFlow", Json::boolean(false)),
        ]),
      ),
    }
    let decoded : @apispec.SecurityScheme = @json.from_json(json)
    assert_eq(Json(decoded), json)
    assert_true(decoded.unmodeled.is_empty())
  }
  assert_eq(Json(@apispec.OAuthFlowObject::new({})), { "scopes": {} })
  let empty : @apispec.OAuthFlows = @json.from_json({
    "implicit": { "scopes": {} },
  })
  assert_eq(empty.implicit.unwrap().scopes, {})
  assert_eq(Json(empty), { "implicit": { "scopes": {} } })
}

///|
test "OAuth field type errors retain JSON paths" {
  let cases : Array[(Json, String)] = [
    ({ "type": "oauth2", "flows": [] }, "/flows"),
    ({ "type": "oauth2", "flows": { "implicit": [] } }, "/flows/implicit"),
    (
      { "type": "oauth2", "flows": { "implicit": {} } },
      "/flows/implicit/scopes",
    ),
    (
      { "type": "oauth2", "flows": { "implicit": { "scopes": { "read": 1 } } } },
      "/flows/implicit/scopes/read",
    ),
  ]
  for (json, path) in cases {
    try {
      let _ : @apispec.SecurityScheme = @json.from_json(json)
    } catch {
      @json.JsonDecodeError((actual, _)) => assert_eq(actual.to_string(), path)
    } noraise {
      _ => fail("invalid OAuth field accepted")
    }
  }
}
