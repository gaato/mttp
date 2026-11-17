///|
pub async fn get_after(base : String) -> (String, Json) {
  let api = @mttp.client(base_url=base)
  defer api.close()
  let text = api.send(@mttp.get("/hello")).body.unwrap()
  let json = api.send(@mttp.get("/json").response(@mttp.as_json_value())).body.unwrap()
  (text, json)
}
