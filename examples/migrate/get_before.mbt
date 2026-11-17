///|
pub async fn get_before(base : String) -> (String, Json) {
  let (_, text) = @http.get(base + "/hello")
  let (_, json) = @http.get(base + "/json")
  (text.text(), json.json())
}
