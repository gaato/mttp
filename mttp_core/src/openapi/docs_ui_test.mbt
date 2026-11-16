///|
test "docs UI pins CDN assets and constrains scripts and connections" {
  for ui in [@openapi.Scalar, @openapi.SwaggerUi] {
    let server = @openapi.docs_ui_endpoint(spec_url="/openapi.json", ui~)
    @driver.run_sync(() => {
      let response = server.dispatch(
        @mttp_core.Request::get("/docs"),
        {},
        @endpoint.DispatchContext::new(),
      )
      assert_eq(response.status, 200)
      assert_eq(
        response.headers.get("content-type"),
        Some("text/html; charset=utf-8"),
      )
      let csp = response.headers.get("content-security-policy").unwrap()
      assert_true(csp.contains("default-src 'none'"))
      assert_true(csp.contains("connect-src 'self'"))
      assert_true(
        csp.contains(
          "base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'",
        ),
      )
      guard response.body is @mttp_core.Bytes(bytes) else {
        fail("buffered page required")
      }
      let html = @schema.text_body.decode(bytes)
      assert_true(html.contains("data-url=\"/openapi.json\""))
      assert_true(
        html.contains(
          "crossorigin=\"anonymous\" referrerpolicy=\"no-referrer\"",
        ),
      )
      match ui {
        Scalar => {
          let bundle = "https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.78.1/dist/browser/standalone.js"
          assert_true(html.contains(bundle))
          assert_true(
            html.contains(
              "sha384-HVpqul+lojb2wwVK554SYr5rD2XqgJZqkYKGl4MyZarBSg+rHR9F0x1LVgzgj7JZ",
            ),
          )
          assert_true(
            csp.contains(
              "script-src " +
              bundle +
              " 'sha384-sbvTF4jm/sVM6FDdRwhIws8BKrFgCAreHT+TTIxDqdlugOe9/x76ZkOU+mvF7kbP'",
            ),
          )
          assert_true(html.contains("withDefaultFonts:false,proxyUrl:\"\""))
        }
        SwaggerUi => {
          let bundle = "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.33.0/swagger-ui-bundle.js"
          assert_true(html.contains(bundle))
          assert_true(
            html.contains(
              "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.33.0/swagger-ui.css",
            ),
          )
          assert_true(
            html.contains(
              "sha384-YDALVcy8kj8yltLBVi1vBiBAUqdxvus673gM8XKwiy6aDUJFXivF/KCufekjYbVf",
            ),
          )
          assert_true(
            html.contains(
              "sha384-Ov4/wv3j2bmct8cDc5X4ngJZohVPzEmc6uDPH8WeljUxO5vtoykvMEfbu9Vh6RaW",
            ),
          )
          assert_true(
            csp.contains(
              "script-src " +
              bundle +
              " 'sha384-Eus8DpoH8G2KKHztDUdXpo4SZ1lltnp4O8IL/nKoDVBKeDn0aXjcskIIyAExtVDW'",
            ),
          )
          assert_true(
            html.contains("validatorUrl:null,supportedSubmitMethods:[]"),
          )
        }
        @openapi.DocsUi::.. => fail("unexpected renderer")
      }
    })
  }
}

///|
test "docs UI keeps hostile URL strings in a single escaped data attribute" {
  for ui in [@openapi.Scalar, @openapi.SwaggerUi] {
    let server = @openapi.docs_ui_endpoint(
      spec_url="/spec?x=\"'&</script><script>alert(1)</script>\\\n\u2028",
      path="/reference",
      ui~,
    )
    @driver.run_sync(() => {
      let response = server.dispatch(
        @mttp_core.Request::get("/reference"),
        {},
        @endpoint.DispatchContext::new(),
      )
      assert_eq(response.status, 200)
      guard response.body is @mttp_core.Bytes(bytes) else {
        fail("buffered page required")
      }
      let html = @schema.text_body.decode(bytes)
      assert_true(
        html.contains(
          "data-url=\"/spec?x=&quot;&#39;&amp;&lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;\\\n\u2028\"",
        ),
      )
      assert_true(!html.contains("<script>alert(1)</script>"))
      assert_true(
        html.contains("url:document.getElementById(\"app\").dataset.url"),
      )
      assert_true(
        !response.headers
        .get("content-security-policy")
        .unwrap()
        .contains("alert"),
      )
    })
  }
}
