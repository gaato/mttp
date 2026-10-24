///|
/// Phase-1 emitter output under the proposed model: the request builder must
/// now raise UrlError (Url is read-only and only a raising parser makes one).
pub fn repos_get_request(
  owner : String,
  repo : String,
) -> @model.Request raise @model.UrlError {
  @model.Request::new(Get, @model.Url::parse("/repos/" + owner + "/" + repo))
}

///|
pub fn issues_list_request(
  owner : String,
  repo : String,
) -> @model.Request raise @model.UrlError {
  @model.Request::new(
    Get,
    @model.Url::parse("/repos/" + owner + "/" + repo + "/issues"),
  )
}

///|
pub(all) struct Issue {
  number : Int
} derive(FromJson, ToJson, Eq, Debug)

///|
/// Phase-1 decoder: (ResponseHead, Bytes) instead of @http.Response.
pub fn issues_list_decode(
  head : @model.ResponseHead,
  body : Bytes,
) -> Array[Issue] raise @client.ResponseError {
  @json.from_json(@json.parse(@utf8.decode(body))) catch {
    e => raise Deserialization(head, message="\{e}", body~)
  }
}
