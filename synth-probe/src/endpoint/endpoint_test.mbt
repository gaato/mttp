///|
suberror ApiError {
  Forbidden
} derive(Debug)

///|
let base : @endpoint.Endpoint[String, Unit, ApiError, Unit] = @endpoint.endpoint
  .path("/api/v1")
  .security(@endpoint.bearer())
  .errors(@endpoint.Errors::new(e => match e { ApiError::_ as a => Some(a); _ => None }))

///|
let get_item : @endpoint.Endpoint[String, Int, ApiError, String] = base
  .get("/items/{id}")
  .input(@endpoint.path_int("id"))
  .output(@endpoint.text_out())

///|
test "set-once builders with appending path and base endpoint" {
  let se = get_item.serve(async fn(t) { if t == "good" { "alice" } else { raise Forbidden } }, async fn(who, id) { "\{who}:\{id}" })
  ignore(se)
}
