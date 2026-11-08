///|
// Count individual validation issues as well as input failures. A single
// schema decoder may return many issues, so slicing only the outer list does
// not bound what the policy callback or the wire response receives.
fn bounded_failures(
  failures : Array[InputFailure],
  max : Int32,
) -> Array[InputFailure] {
  let result = []
  let mut remaining = max
  for failure in failures {
    if remaining <= 0 {
      break
    }
    let @schema.DecodeFailure(kind~, message~) = failure.failure
    match kind {
      Invalid(issues) => {
        let kept = issues[:remaining.min(issues.length())].to_owned()
        remaining -= kept.length().max(1)
        result.push({
          ..failure,
          failure: @schema.DecodeFailure(kind=Invalid(kept), message~),
        })
      }
      _ => {
        remaining -= 1
        result.push(failure)
      }
    }
  }
  result
}

///|
fn problem(
  status : Int32,
  title : String,
  errors : Array[Json],
) -> @http.Response {
  let body : Json = {
    "type": "about:blank",
    "title": Json(title),
    "status": Json(status),
    "errors": Json::array(errors),
  }
  @http.Response::new(
    status,
    headers=@http.Headers::of([("content-type", "application/problem+json")]),
    body=Bytes(@http.encode_utf8(body.stringify())),
  )
}

///|
fn default_failure(context : FailureContext) -> @http.Response {
  let errors : Array[Json] = []
  let mut status = 400
  for f in context.failures {
    let @schema.DecodeFailure(kind~, message~) = f.failure
    if kind is TooLarge(..) {
      status = 413
    }
    if kind is UnsupportedMediaType(_) && status != 413 {
      status = 415
    }
    let location = match f.atom.location {
      Path => "path"
      Query => "query"
      Header => "header"
      Cookie => "cookie"
      Auth(..) => "auth"
      Body(..) | RawBody => "body"
      _ => "derived"
    }
    match kind {
      Invalid(issues) =>
        for issue in issues {
          errors.push({
            "in": Json(location),
            "name": Json(f.atom.name),
            "path": Json(issue.path),
            "code": Json(issue.code),
            "message": Json(issue.message),
          })
        }
      _ =>
        errors.push({
          "in": Json(location),
          "name": Json(f.atom.name),
          "message": Json(message),
        })
    }
  }
  if status == 413 {
    return problem(413, "Content Too Large", errors)
  }
  if context.stage is Security {
    for f in context.failures {
      if f.atom.location is Auth(scheme~, ..) {
        let challenge = match scheme {
          Bearer(..) => "Bearer"
          Basic => "Basic charset=\"UTF-8\""
          _ => "ApiKey"
        }
        let response = problem(401, "Unauthorized", [])
        return {
          ..response,
          headers: response.headers.set("www-authenticate", challenge),
        }
      }
    }
  }
  problem(
    status,
    if status == 415 {
      "Unsupported Media Type"
    } else {
      "Bad Request"
    },
    errors,
  )
}
