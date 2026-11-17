///|
fn oauth_test_flows() -> Array[@endpoint.OAuthFlow] {
  [
    AuthorizationCode(
      authorization_url="https://id.test/auth",
      token_url="https://id.test/token",
      refresh_url=Some("https://id.test/refresh"),
      scopes={ "read": "Read", "write": "Write" },
    ),
    ClientCredentials(token_url="https://id.test/token", refresh_url=None, scopes={
      "service": "Service access",
    }),
  ]
}

///|
fn oauth_spec(version : @openapi.OpenApiVersion) -> @apispec.OpenApi raise {
  let flows = oauth_test_flows()
  @openapi.to_openapi(
    [
      @endpoint.endpoint
      .get("/read")
      .security(@endpoint.oauth2(flows~, scopes=["read"]))
      .doc(),
      @endpoint.endpoint
      .post("/write")
      .security(
        @endpoint.oauth2(flows=flows.rev(), scopes=["write", "read", "read"]),
      )
      .doc(),
      @endpoint.endpoint
      .get("/oidc")
      .security(
        @endpoint.openid_connect(
          "https://id.test/.well-known/openid-configuration",
          scopes=["profile", "openid"],
        ),
      )
      .doc(),
      @endpoint.endpoint.get("/public").doc(),
    ],
    @apispec.Info::new("OAuth", "1"),
    version~,
    security=[{ "oauth2": ["service"], "openIdConnect": ["unverifiable"] }],
  )
}

///|
fn oauth_golden(version : @openapi.OpenApiVersion) -> Json raise {
  let spec = oauth_spec(version)
  assert_eq(@openapi.check_references(spec), [])
  let decoded : @apispec.OpenApi = @json.from_json(Json(spec))
  assert_eq(decoded, spec)
  {
    "openapi": Json(spec.openapi),
    "schemes": Json(spec.components.security_schemes),
    "security": Json(spec.security.unwrap()),
    "operations": Json(
      spec.paths.map((_, item) => {
        item.operations.map((_, operation) => operation.security.unwrap())
      }),
    ),
  }
}

///|
test "OpenAPI 3.1 OAuth2 and OIDC golden" {
  json_inspect(oauth_golden(V3_1), content={
    "openapi": "3.1.0",
    "schemes": {
      "oauth2": {
        "type": "oauth2",
        "flows": {
          "clientCredentials": {
            "tokenUrl": "https://id.test/token",
            "scopes": { "service": "Service access" },
          },
          "authorizationCode": {
            "authorizationUrl": "https://id.test/auth",
            "tokenUrl": "https://id.test/token",
            "refreshUrl": "https://id.test/refresh",
            "scopes": { "read": "Read", "write": "Write" },
          },
        },
      },
      "openIdConnect": {
        "type": "openIdConnect",
        "openIdConnectUrl": "https://id.test/.well-known/openid-configuration",
      },
    },
    "security": [{ "oauth2": ["service"], "openIdConnect": ["unverifiable"] }],
    "operations": {
      "/read": { "get": [{ "oauth2": ["read"] }] },
      "/write": { "post": [{ "oauth2": ["read", "write"] }] },
      "/oidc": { "get": [{ "openIdConnect": ["openid", "profile"] }] },
      "/public": { "get": [] },
    },
  })
}

///|
test "OpenAPI 3.2 OAuth2 and OIDC golden" {
  json_inspect(oauth_golden(V3_2), content={
    "openapi": "3.2.0",
    "schemes": {
      "oauth2": {
        "type": "oauth2",
        "flows": {
          "clientCredentials": {
            "tokenUrl": "https://id.test/token",
            "scopes": { "service": "Service access" },
          },
          "authorizationCode": {
            "authorizationUrl": "https://id.test/auth",
            "tokenUrl": "https://id.test/token",
            "refreshUrl": "https://id.test/refresh",
            "scopes": { "read": "Read", "write": "Write" },
          },
        },
      },
      "openIdConnect": {
        "type": "openIdConnect",
        "openIdConnectUrl": "https://id.test/.well-known/openid-configuration",
      },
    },
    "security": [{ "oauth2": ["service"], "openIdConnect": ["unverifiable"] }],
    "operations": {
      "/read": { "get": [{ "oauth2": ["read"] }] },
      "/write": { "post": [{ "oauth2": ["read", "write"] }] },
      "/oidc": { "get": [{ "openIdConnect": ["openid", "profile"] }] },
      "/public": { "get": [] },
    },
  })
}

///|
test "OAuth requirements union scopes per scheme with AND and optional semantics" {
  let flows = oauth_test_flows()
  let a = @endpoint.oauth2(flows~, scopes=["write", "read", "write"])
  let b = @endpoint.oauth2(flows~, scopes=["service", "read"])
  let ep = @endpoint.endpoint
    .get("/")
    .security(
      @endpoint.pair(@endpoint.pair(a, b.optional()), @endpoint.bearer()),
    )
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  assert_eq(
    spec.paths["/"].operations["get"].security,
    Some([
      { "oauth2": ["read", "write"], "bearer": [] },
      { "oauth2": ["read", "service", "write"], "bearer": [] },
    ]),
  )
  let ep = @endpoint.endpoint.get("/").security(a.optional())
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  assert_eq(
    spec.paths["/"].operations["get"].security,
    Some([{}, { "oauth2": ["read", "write"] }]),
  )
  // Ordinary input Auth atoms share the same projection and definition rules.
  let ep = @endpoint.endpoint.get("/").input(@endpoint.pair(a, b))
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  assert_eq(
    spec.paths["/"].operations["get"].security,
    Some([{ "oauth2": ["read", "service", "write"] }]),
  )
}

///|
test "DeviceAuthorization projects only in OpenAPI 3.2 and names the scheme on refusal" {
  let flows : Array[@endpoint.OAuthFlow] = [
    DeviceAuthorization(
      device_authorization_url="https://id.test/device",
      token_url="https://id.test/token",
      refresh_url=Some("https://id.test/refresh"),
      scopes={ "read": "Read" },
    ),
  ]
  let ep = @endpoint.endpoint
    .get("/")
    .security(@endpoint.oauth2(flows~, scheme_name="device", scopes=["read"]))
  assert_eq(@endpoint.check_definitions([ep.doc()]), [])
  try
    ignore(@openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1")))
  catch {
    @endpoint.DefinitionError(problems) => {
      assert_eq(problems.length(), 1)
      assert_true(problems[0].fatal)
      assert_eq(
        problems[0].message,
        "OAuth2 scheme device uses deviceAuthorization which requires OpenAPI 3.2",
      )
    }
  } noraise {
    _ => fail("device flow accepted in 3.1")
  }
  let spec = @openapi.to_openapi(
    [ep.doc()],
    @apispec.Info::new("Test", "1"),
    version=V3_2,
  )
  json_inspect(spec.components.security_schemes["device"], content={
    "type": "oauth2",
    "flows": {
      "deviceAuthorization": {
        "tokenUrl": "https://id.test/token",
        "refreshUrl": "https://id.test/refresh",
        "deviceAuthorizationUrl": "https://id.test/device",
        "scopes": { "read": "Read" },
      },
    },
  })
}

///|
test "implicit and password flows project their required and refresh URLs" {
  let flows : Array[@endpoint.OAuthFlow] = [
    Implicit(
      authorization_url="https://id.test/auth",
      refresh_url=Some("https://id.test/refresh"),
      scopes={},
    ),
    Password(
      token_url="https://id.test/token",
      refresh_url=Some("https://id.test/refresh"),
      scopes={},
    ),
  ]
  for version in [@openapi.V3_1, @openapi.V3_2] {
    let ep = @endpoint.endpoint.get("/").security(@endpoint.oauth2(flows~))
    let spec = @openapi.to_openapi(
      [ep.doc()],
      @apispec.Info::new("Test", "1"),
      version~,
    )
    json_inspect(spec.components.security_schemes["oauth2"], content={
      "type": "oauth2",
      "flows": {
        "implicit": {
          "authorizationUrl": "https://id.test/auth",
          "refreshUrl": "https://id.test/refresh",
          "scopes": {},
        },
        "password": {
          "tokenUrl": "https://id.test/token",
          "refreshUrl": "https://id.test/refresh",
          "scopes": {},
        },
      },
    })
  }
}

///|
test "OAuth projection refuses conflicting flows URLs and undeclared root scopes" {
  let a = @endpoint.endpoint
    .get("/a")
    .security(@endpoint.oauth2(flows=oauth_test_flows()))
    .doc()
  let b = @endpoint.endpoint
    .get("/b")
    .security(
      @endpoint.oauth2(flows=[
        ClientCredentials(
          token_url="https://different.test/token",
          refresh_url=None,
          scopes={},
        ),
      ]),
    )
    .doc()
  let oidc_a = @endpoint.endpoint
    .get("/a")
    .security(@endpoint.openid_connect("https://one.test/discovery"))
    .doc()
  let oidc_b = @endpoint.endpoint
    .get("/b")
    .security(@endpoint.openid_connect("https://two.test/discovery"))
    .doc()
  for
    (docs, root, message) in [
      ([a, b], [], "conflicting security scheme oauth2"),
      ([oidc_a, oidc_b], [], "conflicting security scheme openIdConnect"),
      (
        [a],
        [{ "oauth2": ["missing"] }],
        "OAuth2 scheme oauth2 requires undeclared document scope missing",
      ),
    ] {
    try
      ignore(
        @openapi.to_openapi(
          docs,
          @apispec.Info::new("Test", "1"),
          security=root,
        ),
      )
    catch {
      @endpoint.DefinitionError(problems) =>
        assert_true(problems.iter().any(p => p.fatal && p.message == message))
    } noraise {
      _ => fail("invalid security definition accepted")
    }
  }
}
