// What derive(ToJson) can emit for an enum (OpenAPI APIs want {"type":"a", ...fields}).
enum T0 { A0(x~ : Int); B0(y~ : String) } derive(ToJson)
enum T1 { A1(x~ : Int); B1(y~ : String) } derive(ToJson(repr(tag="type")))
enum T2 { A2(x~ : Int); B2(y~ : String) } derive(ToJson(repr(tag="type", contents="data")))
enum T3 { A3(x~ : Int); B3(y~ : String) } derive(ToJson(style="flat"))
enum T4 { A4(x~ : Int); B4(y~ : String) } derive(ToJson(style="legacy"))

test "derive enum representations" {
  inspect([A0(x=1), B0(y="s")].to_json().stringify(), content=(
    #|[["A0",{"x":1}],["B0",{"y":"s"}]]
  ))
  inspect([A1(x=1), B1(y="s")].to_json().stringify(), content=(
    #|[["A1",{"x":1}],["B1",{"y":"s"}]]
  ))
  inspect([A2(x=1), B2(y="s")].to_json().stringify(), content=(
    #|[{"type":"A2","data":[{"x":1}]},{"type":"B2","data":[{"y":"s"}]}]
  ))
  inspect([A3(x=1), B3(y="s")].to_json().stringify(), content=(
    #|[["A3",{"x":1}],["B3",{"y":"s"}]]
  ))
  inspect([A4(x=1), B4(y="s")].to_json().stringify(), content=(
    #|[{"$tag":"A4","x":1},{"$tag":"B4","y":"s"}]
  ))
}
