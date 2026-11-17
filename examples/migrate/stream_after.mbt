///|
pub async fn stream_after(base : String) -> Int64 {
  let api = @mttp.client(base_url=base)
  defer api.close()
  api.send(
    @mttp.get("/stream").response(
      @mttp.ResponsePlan::stream((_, body, _) => {
        let mut size = 0L
        while body.read_some() is Some(chunk) {
          size += chunk.length().to_int64()
        }
        size
      }),
    ),
  ).body.unwrap()
}
