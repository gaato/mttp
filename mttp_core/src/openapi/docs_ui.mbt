///|
/// The documentation renderer loaded from a version-pinned CDN bundle.
#non_exhaustive
pub(all) enum DocsUi {
  Scalar
  SwaggerUi
}

///|
/// Serves a buffered HTML documentation page. `spec_url` should be same-origin:
/// CSP permits fetching the specification from self, and assets only from the
/// pinned jsDelivr URLs. External fonts, proxies and Swagger's validator are
/// disabled. Inline styles are required by the renderers; inline scripts are
/// authorized only by their fixed hashes.
pub fn docs_ui_endpoint(
  spec_url~ : String,
  path~ : String = "/docs",
  ui~ : DocsUi = Scalar,
) -> @endpoint.ServerEndpoint {
  // Keep URL data out of executable JS. HTML-escape it once at the quoted
  // attribute boundary; dataset returns the original string to the renderer.
  let escaped = StringBuilder()
  for c in spec_url {
    match c {
      '&' => escaped.write_string("&amp;")
      '<' => escaped.write_string("&lt;")
      '>' => escaped.write_string("&gt;")
      '"' => escaped.write_string("&quot;")
      '\'' => escaped.write_string("&#39;")
      _ => escaped.write_char(c)
    }
  }
  let url = escaped.to_string()
  let (bundle, integrity, initialize, initialize_hash, css) = match ui {
    Scalar =>
      (
        "https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.78.1/dist/browser/standalone.js",
        "sha384-HVpqul+lojb2wwVK554SYr5rD2XqgJZqkYKGl4MyZarBSg+rHR9F0x1LVgzgj7JZ",
        "Scalar.createApiReference(\"#app\",{url:document.getElementById(\"app\").dataset.url,withDefaultFonts:false,proxyUrl:\"\"});",
        "sha384-sbvTF4jm/sVM6FDdRwhIws8BKrFgCAreHT+TTIxDqdlugOe9/x76ZkOU+mvF7kbP",
        "",
      )
    SwaggerUi =>
      (
        "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.33.0/swagger-ui-bundle.js",
        "sha384-YDALVcy8kj8yltLBVi1vBiBAUqdxvus673gM8XKwiy6aDUJFXivF/KCufekjYbVf",
        "SwaggerUIBundle({url:document.getElementById(\"app\").dataset.url,dom_id:\"#app\",validatorUrl:null,supportedSubmitMethods:[]});",
        "sha384-Eus8DpoH8G2KKHztDUdXpo4SZ1lltnp4O8IL/nKoDVBKeDn0aXjcskIIyAExtVDW",
        "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.33.0/swagger-ui.css\" integrity=\"sha384-Ov4/wv3j2bmct8cDc5X4ngJZohVPzEmc6uDPH8WeljUxO5vtoykvMEfbu9Vh6RaW\" crossorigin=\"anonymous\" referrerpolicy=\"no-referrer\">",
      )
  }
  let csp = "default-src 'none'; script-src \{bundle} '\{initialize_hash}'; style-src https://cdn.jsdelivr.net 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'none'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'"
  let page = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"referrer\" content=\"no-referrer\"><title>API documentation</title>\{css}</head><body><div id=\"app\" data-url=\"\{url}\"></div><script src=\"\{bundle}\" integrity=\"\{integrity}\" crossorigin=\"anonymous\" referrerpolicy=\"no-referrer\"></script><script>\{initialize}</script></body></html>"
  @endpoint.endpoint
  .get(path)
  .output(
    @endpoint.html_out().and_header("content-security-policy", @schema.string),
  )
  .serve_public(_ => Ok((page, csp)))
}
