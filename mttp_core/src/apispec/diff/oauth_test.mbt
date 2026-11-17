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
test "OAuth scope named $ref is ordinary data alongside sibling scopes" {
  let before = oauth_doc({
    "implicit": {
      "authorizationUrl": "https://id.test/auth",
      "scopes": { "$ref": "Reference access", "read": "Old description" },
    },
  })
  let after = oauth_doc({
    "implicit": {
      "authorizationUrl": "https://id.test/auth",
      "scopes": { "read": "New description" },
    },
  })
  for
    (a, b, severity) in [
      (before, after, @diff.Breaking),
      (after, before, @diff.Info),
    ] {
    let result = @diff.compare(a, b)
    assert_eq(result.request.length(), 2)
    assert_eq(result.response, [])
    assert_true(result.complete())
    assert_true(
      result.request
      .iter()
      .any(c => {
        c.path == "/components/securitySchemes/oauth/flows/implicit/scopes/$ref" &&
        c.kind is KeywordChanged(keyword="$ref", ..) &&
        c.client == severity &&
        c.server == severity
      }),
    )
    assert_true(
      result.request
      .iter()
      .any(c => {
        c.path == "/components/securitySchemes/oauth/flows/implicit/scopes/read" &&
        c.kind is KeywordChanged(keyword="read", ..) &&
        c.client == @diff.Info &&
        c.server == @diff.Info
      }),
    )
  }
  let described = oauth_doc({
    "implicit": {
      "authorizationUrl": "https://id.test/auth",
      "scopes": { "$ref": "New description", "read": "Old description" },
    },
  })
  let result = @diff.compare(before, described)
  assert_eq(result.request.length(), 1)
  assert_true(result.request[0].kind is KeywordChanged(keyword="$ref", ..))
  assert_eq(result.request[0].client, @diff.Info)
}

///|
test "unchanged security scheme references compare external component targets" {
  let before : Json = {
    "type": "oauth2",
    "flows": {
      "implicit": {
        "authorizationUrl": "https://id.test/auth",
        "scopes": { "read": "Read" },
      },
    },
  }
  let cases : Array[(Json, String)] = [
    ({ "type": "oauth2", "flows": {} }, "/flows/implicit"),
    (
      {
        "type": "oauth2",
        "flows": {
          "implicit": {
            "authorizationUrl": "https://id.test/auth",
            "scopes": {},
          },
        },
      },
      "/flows/implicit/scopes/read",
    ),
  ]
  for (target, suffix) in cases {
    for changed_sibling in [false, true] {
      let schemes : Map[String, Json] = { "oauth": { "$ref": "#/x-auth" } }
      let a = doc({}, components={ "securitySchemes": Json(schemes.copy()) })
      if changed_sibling {
        schemes["basic"] = { "type": "http", "scheme": "basic" }
      }
      let b = doc({}, components={ "securitySchemes": Json(schemes) })
      let a = { ..a, extensions: { "x-auth": before }, }
      let b = { ..b, extensions: { "x-auth": target }, }
      let result = @diff.compare(a, b)
      assert_eq(result.request.length(), if changed_sibling { 2 } else { 1 })
      assert_eq(result.response, [])
      assert_true(result.complete())
      assert_true(
        result.request
        .iter()
        .any(c => {
          c.path == "/x-auth" + suffix &&
          c.kind is KeywordChanged(..) &&
          c.client == @diff.Breaking &&
          c.server == @diff.Breaking
        }),
      )
      let limited = @diff.compare(a, b, max_nodes=4)
      assert_false(limited.complete())
      assert_eq(
        limited.request.iter().filter(c => c.kind is LimitReached(..)).count(),
        1,
      )
    }
  }
  let cycle = doc({}, components={
    "securitySchemes": { "oauth": { "$ref": "#/x-auth" } },
  })
  let cycle = { ..cycle, extensions: { "x-auth": { "$ref": "#/x-auth" } }, }
  let result = @diff.compare(cycle, cycle, max_nodes=100)
  assert_true(result.complete())
  assert_eq(result.request, [])
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
