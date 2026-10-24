test "201 Created + Location header round trip" {
  let created = @o.json_out(status=201).and_header("Location")
  let w = created.write(({ "id": 7 }, "/users/7"))
  inspect(w.status, content=(
    #|201
  ))
  inspect(w.headers, content=(
    #|[(Location, /users/7)]
  ))
  let (body, loc) = (created.decode)(w)
  inspect(body.stringify(), content=(
    #|{"id":7}
  ))
  inspect(loc, content=(
    #|/users/7
  ))
}

test "dynamic status (proxy-style endpoint)" {
  let o = @o.json_out().and_status()
  let w = o.write(({ "ok": false }, 202))
  inspect(w.status, content=(
    #|202
  ))
}

test "content negotiation: JSON or CSV at one status, 406 otherwise" {
  let o : @o.Out[Array[Int]] = @o.one_of_body(200, [
    ("application/json", xs => @utf8.encode(xs.to_json().stringify()), b => { let _ = b; [] }),
    ("text/csv", xs => @utf8.encode(xs.map(x => x.to_string()).join(",")), b => (@utf8.decode(b) catch { _ => raise @o.Mismatch("utf8") }).split(",").map(s => @string.parse_int(s.to_string()) catch { _ => 0 }).collect()),
  ])
  inspect(o.write([1, 2], accept="text/csv").media, content=(
    #|Some(text/csv)
  ))
  inspect(o.write([1, 2], accept="application/json").media, content=(
    #|Some(application/json)
  ))
  let r = try { Ok(o.write([1, 2], accept="application/xml")) } catch { e => Err(e) }
  inspect(r is Err(NotAcceptable(_)), content=(
    #|true
  ))
  inspect((o.decode)(o.write([3, 4], accept="text/csv")), content=(
    #|[3, 4]
  ))
}
