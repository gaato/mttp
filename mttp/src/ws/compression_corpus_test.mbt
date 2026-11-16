///|
fn corpus_member_train(count : Int32) -> Bytes {
  Bytes::makei(count * 2 + 1, i => {
    if i < count * 2 && i % 2 == 0 {
      3
    } else {
      0
    }
  })
}

///|
// check_splits has a synchronous callback. Schedule the public async API
// checks for every partition, then join them; each checks the same expected
// message/error and wire Close. No private codec or alternate runtime is used.
async fn check_session_splits(
  wire : Bytes,
  visit : async (Array[Bytes]) -> Unit,
) -> Unit {
  @async.with_timeout(10000, () => {
    @async.with_task_group(group => {
      let jobs : Array[@async.Task[Unit]] = []
      @sim.check_splits(wire, chunks => {
        jobs.push(group.spawn(() => visit(chunks)))
      })
      for job in jobs {
        job.wait()
      }
    })
  })
}

///|
async fn check_compressed_corpus(
  role : @frame.Role,
  payload : Bytes,
  expected_status : Int32,
  expected_message : @core_ws.Message?,
) -> Unit {
  let mask = if role is Server { Some(b"abcd") } else { None }
  let data = match mask {
    Some(key) => @frame.apply_mask(payload, key)
    None => payload
  }
  let wire = @frame.encode_head(
      {
        fin: true,
        rsv1: true,
        opcode: if expected_message is Some(Text(_)) {
          Text
        } else {
          Binary
        },
        masked: mask is Some(_),
        length: payload.length().to_int64(),
      },
      mask?,
    ) +
    data
  check_session_splits(wire, chunks => {
    let conn = @sim.ScriptedConn::new(
      chunks.filter(c => !c.is_empty()).map(c => @sim.ReadStep::Chunk(c)),
    )
    let received : Ref[@core_ws.Message?] = Ref(None)
    let status = Ref(0)
    let consume : async (&@core_ws.Session) -> Unit = session => {
      try session.recv() catch {
        @core_ws.WsError(kind=Protocol, ..) => status.val = 1002
        @core_ws.WsError(kind=TooLarge(limit=8), ..) => status.val = 1009
        _ => status.val = -1
      } noraise {
        message => {
          received.val = Some(message)
          status.val = 1
        }
      }
      session.abort()
    }
    let limits = {
      ..@core_ws.WsLimits::default(),
      max_frame_bytes: 2097152,
      max_message_bytes: 2097152,
      ping_interval_ms: None,
      pong_timeout_ms: None,
    }
    if role is Client {
      let backend = ReplyBackend::{
        run: request => {
          let response = @mttp_core.Response::new(
            101,
            headers=@mttp_core.Headers::of([
              ("connection", "Upgrade"),
              ("upgrade", "websocket"),
              (
                "sec-websocket-accept",
                @handshake.accept_value(
                  request.headers.get("sec-websocket-key").unwrap(),
                ),
              ),
              (
                "sec-websocket-extensions", "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
              ),
            ]),
          )
          {
            ..response,
            attributes: response.attributes.put(@rt.upgraded, TakenConn::{
              conn,
              taken: false,
            }),
          }
        },
      }
      let session = @ws.connect(
        "ws://example.test/",
        backend~,
        limits~,
        compression=@ws.Compression::new(),
      )
      defer session.abort()
      consume(session)
    } else {
      let request = @handshake.client_request(
        "ws://example.test/",
        key="dGhlIHNhbXBsZSBub25jZQ==",
        extensions=["permessage-deflate; client_max_window_bits"],
      )
      let response = @ws.upgrade(
        request,
        limits~,
        compression=@ws.Compression::new(),
        handler=consume,
      )
      defer response.close()
      assert_eq(response.status, 101)
      let upgrade = response.attributes.get(@rt.upgrade).unwrap()
      upgrade(conn, b"", () => false)
    }
    assert_eq(status.val, expected_status)
    assert_eq(received.val, expected_message)
    assert_eq(conn.closes(), 1)
    if expected_status == 1 {
      assert_true(conn.written().is_empty())
    } else {
      let peer = if role is Client {
        @frame.Role::Server
      } else {
        @frame.Role::Client
      }
      let parser = @frame.Parser::new(
        role=peer,
        max_frame_bytes=125,
        allow_rsv1=false,
      )
      for packet in conn.written() {
        parser.feed(packet)
      }
      let close = Ref(0)
      while parser.next() is Some(event) {
        match event {
          Head(head) => assert_true(head.opcode is Close && !head.rsv1)
          Payload(bytes) =>
            close.val = @core_ws.CloseFrame::parse(bytes).code.to_int()
          End => ()
        }
      }
      assert_eq(close.val, expected_status)
    }
  })
}

///|
async test "DEFLATE security corpus refuses member trains and fabricated stored bytes under every split" {
  // The bounded train represents the MiB attack without a quadratic
  // million-split test; the full-size train is checked by the white-box test.
  for
    (payload, expected) in [
      (corpus_member_train(9), 1009),
      (b"\x01\x09\x00\xf6\xff", 1002),
      (b"\x01\x04\x00\xfb\xff", 1002),
      (b"\x00\x04\x00\xfb\xff", 1002),
      (b"\x00\x01\x00", 1002),
      // A final stream without the following empty stored-block prefix
      // cannot reach a block boundary when the RFC tail is restored.
      (b"\xf3\x48\xcd\xc9\xc9\x07\x00", 1002),
      (b"\x03\x00", 1002),
      (b"", 1002),
    ] {
    for role in [@frame.Role::Client, @frame.Role::Server] {
      check_compressed_corpus(role, payload, expected, None)
    }
  }
}

///|
async test "RFC 7692 final streams pass both roles while tail payload is refused" {
  for
    (payload, expected) in [
      // RFC 7692 section 7.2.3.4, including its empty stored-block prefix.
      (b"\xf3\x48\xcd\xc9\xc9\x07\x00\x00", "Hello"),
      (b"\x01", ""),
      (b"\x00", ""),
      (corpus_member_train(2), ""),
    ] {
    for role in [@frame.Role::Client, @frame.Role::Server] {
      check_compressed_corpus(role, payload, 1, Some(Text(expected)))
    }
  }
}

///|
async test "DEFLATE fixed Huffman boundary must reject an unfinished stored header" {
  // Five 9-bit literal-144 codes end at a byte boundary. The appended tail
  // reads as EOB, then stored LEN=ffff with missing NLEN and no extra output.
  for role in [@frame.Role::Client, @frame.Role::Server] {
    check_compressed_corpus(role, b"\x9a\x30\x61\xc2\x84\x09", 1002, None)
  }
}
