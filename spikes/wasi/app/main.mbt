///|
pub async fn start() -> Unit {
  let (stream, sink) = @async-core.Stream::new()
  let done = @stdout.write_via_stream(stream)
  out.val = Some(sink)
  defer {
    out.val = None
    sink.close()
    ignore(done.get())
  }
  stage1() catch {
    e => say("stage1 failed: \{e}")
  }
  stage2() catch {
    e => say("stage2 failed: \{e}")
  }
  stage3() catch {
    e => say("stage3 failed: " + describe(e))
  }
  stage3_rule3() catch {
    e => say("stage3 rule 3 failed: " + describe(e))
  }
}

///|
async fn stage1() -> Unit {
  let headers = @http.Fields::fields()
  let (_trailer_future, trailer_promise) = @async-core.Future::new()
  ignore(trailer_promise)
  let trailers = @async-core.Future::ready(Ok(None))
  let (req, _sent) = @http.Request::new(headers, None, trailers, None)
  ignore(req.set_scheme(Some(@http.Scheme::Http)))
  ignore(req.set_authority(Some("127.0.0.1:18765")))
  ignore(req.set_path_with_query(Some("/hello")))
  match @hclient.send(req) {
    Err(code) => say("send failed: " + @debug.to_string(code))
    Ok(resp) => {
      say("status \{resp.get_status_code()}")
      let (body, _trailers) = @http.Response::consume_body(
        resp,
        @async-core.Future::ready(Ok(())),
      )
      let buf = @buffer.new()
      while body.read(4096) is Some(chunk) {
        for b in chunk {
          buf.write_byte(b)
        }
      }
      say("body \{@utf8.decode_lossy(buf.to_bytes())}")
    }
  }
}
