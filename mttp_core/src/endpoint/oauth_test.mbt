///|
fn oauth_test_inputs() -> Array[@endpoint.Input[String]] {
  [
    @endpoint.oauth2(
      flows=[
        ClientCredentials(token_url="https://id.test/token", refresh_url=None, scopes={
          "read": "Read",
        }),
      ],
      scopes=["read"],
    ),
    @endpoint.openid_connect(
      "https://id.test/.well-known/openid-configuration",
      scopes=["openid"],
    ),
  ]
}

///|
test "OAuth2 and OIDC encode decode the same Bearer wire credential" {
  for input in oauth_test_inputs() {
    let ep = @endpoint.endpoint
      .get("/secure")
      .security(input)
      .output(@endpoint.text_out())
    let server = ep.serve(token => Ok(token), (token, _) => Ok(token))
    @driver.run_sync(() => {
      let encoded = ep.request("opaque-token", ()).raw()
      assert_eq(encoded.headers.get_all("authorization"), [
        "Bearer opaque-token",
      ])
      for
        request in [
          encoded,
          @mttp_core.Request::get("/secure").header(
            "Authorization", "bEaReR  opaque-token",
          ),
        ] {
        let response = server.dispatch(
          request,
          {},
          @endpoint.DispatchContext::new(),
        )
        assert_eq(response.status, 200)
        assert_eq(response.body, @mttp_core.Bytes(b"opaque-token"))
      }
    })
  }
}

///|
test "OAuth2 and OIDC retain Bearer errors and challenges without leaking tokens" {
  let context = @endpoint.DispatchContext::new()
  for input in oauth_test_inputs() {
    let server = @endpoint.endpoint
      .get("/")
      .security(input)
      .serve(_ => Ok(()), (_, _) => Ok(()))
    let bearer = @endpoint.endpoint
      .get("/")
      .security(@endpoint.bearer())
      .serve(_ => Ok(()), (_, _) => Ok(()))
    @driver.run_sync(() => {
      for
        request in [
          @mttp_core.Request::get("/"),
          @mttp_core.Request::get("/").header("authorization", "Bearer"),
          @mttp_core.Request::get("/").header("authorization", "Basic secret"),
          @mttp_core.Request::get("/").header("authorization", "Bearer a b"),
          @mttp_core.Request::get("/").header("authorization", "Bearer a\tb"),
          @mttp_core.Request::get("/")
          .header("authorization", "Bearer first")
          .header("Authorization", "Bearer second"),
        ] {
        let actual = server.dispatch(request, {}, context)
        let expected = bearer.dispatch(request, {}, context)
        assert_eq(actual.status, 401)
        assert_eq(actual.status, expected.status)
        assert_eq(actual.headers.get("www-authenticate"), Some("Bearer"))
        assert_eq(actual.headers, expected.headers)
        assert_eq(actual.body, expected.body)
      }
    })
  }
}

///|
test "OAuth2 definitions reject empty duplicate flows and undeclared required scopes" {
  let flow : @endpoint.OAuthFlow = ClientCredentials(
    token_url="https://id.test/token",
    refresh_url=None,
    scopes={ "read": "Read" },
  )
  for
    (flows, scopes, message) in [
      ([], [], "OAuth2 scheme oauth2 has no flows"),
      ([flow, flow], [], "OAuth2 scheme oauth2 repeats flow clientCredentials"),
      (
        [flow],
        ["write"],
        "OAuth2 scheme oauth2 requires undeclared scope write",
      ),
    ] {
    for regular in [false, true] {
      let input = @endpoint.oauth2(flows~, scopes~)
      let doc = if regular {
        @endpoint.endpoint.get("/").input(input).doc()
      } else {
        @endpoint.endpoint.get("/").security(input).doc()
      }
      let problems = @endpoint.check_definitions([doc])
      assert_eq(problems.length(), 1)
      assert_eq(problems[0].template, "/")
      assert_eq(problems[0].message, message)
      assert_true(problems[0].fatal)
    }
  }
  let second : @endpoint.OAuthFlow = Implicit(
    authorization_url="https://id.test/auth",
    refresh_url=None,
    scopes={ "write": "Write" },
  )
  assert_eq(
    @endpoint.check_definitions([
      @endpoint.endpoint
      .get("/")
      .security(
        @endpoint.oauth2(flows=[flow, second], scopes=["read", "write"]),
      )
      .doc(),
    ]),
    [],
  )
}
