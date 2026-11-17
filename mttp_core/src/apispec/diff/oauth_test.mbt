///|
fn oauth_doc(flows : Json) -> @apispec.OpenApi raise {
  doc(
    {
      "/x": { "get": { "responses": {}, "security": [{ "oauth": ["read"] }] } },
    },
    components={
      "securitySchemes": { "oauth": { "type": "oauth2", "flows": flows } },
    },
  )
}

///|
test "every OAuth flow and scope removal breaks clients and additions are informational" {
  for
    kind in [
      "implicit", "password", "clientCredentials", "authorizationCode", "deviceAuthorization",
    ] {
    let flow : Json = {
      "authorizationUrl": "https://id.test/auth",
      "tokenUrl": "https://id.test/token",
      "scopes": { "read": "Read" },
    }
    let before = oauth_doc(Json::object(Map::from_array([(kind, flow)])))
    let after = oauth_doc({})
    let removed = @diff.compare(before, after)
    assert_eq(removed.response, [])
    assert_eq(removed.request.length(), 1)
    assert_eq(
      removed.request[0].path,
      "/components/securitySchemes/oauth/flows/" + kind,
    )
    assert_eq(removed.request[0].client, @diff.Breaking)
    assert_eq(@diff.compare(after, before).request[0].client, @diff.Info)
    let less : Json = {
      "authorizationUrl": "https://id.test/auth",
      "tokenUrl": "https://id.test/token",
      "scopes": {},
    }
    let narrowed = oauth_doc(Json::object(Map::from_array([(kind, less)])))
    let scope_removed = @diff.compare(before, narrowed)
    assert_eq(scope_removed.request.length(), 1)
    assert_eq(
      scope_removed.request[0].path,
      "/components/securitySchemes/oauth/flows/" + kind + "/scopes/read",
    )
    assert_eq(scope_removed.request[0].client, @diff.Breaking)
    assert_eq(@diff.compare(narrowed, before).request[0].client, @diff.Info)
    assert_true(
      @diff.compare(before, narrowed, max_nodes=1).request
      .iter()
      .any(c => c.kind is LimitReached(..)),
    )
    let only_schemes = @apispec.OpenApi::new(
      @apispec.Info::new("Test", "1"),
      components=before.components,
    )
    let no_schemes = @apispec.OpenApi::new(
      @apispec.Info::new("Test", "1"),
      components=after.components,
    )
    let limited = @diff.compare(only_schemes, no_schemes, max_nodes=1)
    assert_false(limited.complete())
    assert_true(
      limited.request.iter().any(change => change.kind is LimitReached(..)),
    )
  }
}

///|
test "OAuth flow URLs and scope descriptions have explicit diff findings" {
  for
    key in [
      "authorizationUrl", "tokenUrl", "refreshUrl", "deviceAuthorizationUrl",
    ] {
    let a : Map[String, Json] = { "scopes": {} }
    a[key] = Json::string("https://id.test/old")
    let b = a.copy()
    b[key] = Json::string("https://id.test/new")
    let result = @diff.compare(
      oauth_doc({ "authorizationCode": Json(a) }),
      oauth_doc({ "authorizationCode": Json(b) }),
    )
    assert_eq(result.request.length(), 1)
    assert_eq(
      result.request[0].path,
      "/components/securitySchemes/oauth/flows/authorizationCode/" + key,
    )
    assert_eq(result.request[0].client, @diff.Warning)
    assert_true(
      result.request[0].kind is KeywordChanged(keyword~, ..) && keyword == key,
    )
  }
  let a = oauth_doc({
    "implicit": {
      "authorizationUrl": "https://id.test/auth",
      "scopes": { "read": "Old description" },
    },
  })
  let b = oauth_doc({
    "implicit": {
      "authorizationUrl": "https://id.test/auth",
      "scopes": { "read": "New description" },
    },
  })
  assert_eq(@diff.compare(a, b).request[0].client, @diff.Info)
  let scheme = a.components.security_schemes["oauth"]
  let no_flows = {
    ..a,
    components: @apispec.Components::new(security_schemes={
      "oauth": { ..scheme, flows: None, },
    }),
  }
  assert_eq(@diff.compare(a, no_flows).request[0].client, @diff.Breaking)
  let referenced = {
    ..a,
    components: @apispec.Components::new(security_schemes={
      "oauth": @apispec.SecurityScheme::new("oauth2", unmodeled={
        "$ref": "#/components/securitySchemes/target",
      }),
      "target": scheme,
    }),
  }
  assert_true(
    @diff.compare(referenced, b).request
    .iter()
    .any(c => c.kind is RefTargetChanged(..)),
  )
  let oidc = @apispec.SecurityScheme::new(
    "openIdConnect",
    open_id_connect_url="https://id.test/old",
  )
  let old = {
    ..a,
    components: @apispec.Components::new(security_schemes={ "oidc": oidc }),
  }
  let new = {
    ..a,
    components: @apispec.Components::new(security_schemes={
      "oidc": { ..oidc, open_id_connect_url: Some("https://id.test/new"), },
    }),
  }
  let result = @diff.compare(old, new)
  assert_eq(result.request.length(), 1)
  assert_eq(
    result.request[0].path,
    "/components/securitySchemes/oidc/openIdConnectUrl",
  )
  assert_eq(result.request[0].client, @diff.Warning)
  let extended = oauth_doc({
    "implicit": {
      "authorizationUrl": "https://id.test/auth",
      "scopes": { "read": "Old description" },
    },
    "futureFlow": { "url": "https://id.test/future" },
    "x-note": "annotation",
  })
  let result = @diff.compare(extended, a)
  assert_eq(result.request.length(), 2)
  assert_true(
    result.request.iter().all(change => change.client == @diff.Warning),
  )
}
