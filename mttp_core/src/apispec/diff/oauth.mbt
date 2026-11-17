///|
// Keep flow and scope changes under the comparator's existing node budget.
// Removing an advertised credential path narrows what a client may send.
fn State::security_fields(s : State, w : Work) -> Unit {
  for key in keys(w.old, w.new) {
    if !s.visit(pointer(w.path, key)) {
      break
    }
    let a = obj(w.old).get(key)
    let b = obj(w.new).get(key)
    // Scope names are arbitrary strings; "$ref" is data in a scopes map.
    // An equal scheme wrapper can still point at a changed document target.
    let follow_reference = w.context == "security-schemes" &&
      (
        (a is Some(value) && text(field(value, "$ref")) != None) ||
        (b is Some(value) && text(field(value, "$ref")) != None)
      )
    if (a == b && !follow_reference) ||
      (key == "$ref" && w.context != "oauth-scopes") {
      continue
    }
    let context = match w.context {
      "security-schemes" => Some("security-scheme")
      "security-scheme" =>
        if key == "flows" {
          Some("oauth-flows")
        } else {
          None
        }
      "oauth-flows" =>
        if [
            "implicit", "password", "clientCredentials", "authorizationCode", "deviceAuthorization",
          ].contains(key) {
          Some("oauth-flow")
        } else {
          None
        }
      "oauth-flow" => if key == "scopes" { Some("oauth-scopes") } else { None }
      _ => None
    }
    // Descend an added/removed flows or scopes map too, so each lost flow or
    // scope has its own source pointer. Whole flow removals need one finding.
    if context is Some(context) &&
      (
        (a != None && b != None) ||
        context == "oauth-flows" ||
        context == "oauth-scopes"
      ) {
      s.push(
        a.unwrap_or(Json::empty_object()),
        b.unwrap_or(Json::empty_object()),
        pointer(w.path, key),
        Request,
        context,
      )
    } else {
      let membership = w.context == "security-schemes" ||
        context == Some("oauth-flow") ||
        w.context == "oauth-scopes"
      let severity = if membership && b == None {
        Breaking
      } else if membership && a == None {
        Info
      } else if w.context == "oauth-scopes" {
        Info
      } else {
        Warning
      }
      s.emit(
        Request,
        pointer(w.path, key),
        KeywordChanged(keyword=key, old=a, new=b),
        severity,
        severity,
      )
    }
  }
}
