///|
/// A host environment shaped like a Workers `env`: a string var, a JSON var,
/// a binding object, inherited properties and a getter that throws.
extern "js" fn workers_like_env() -> @fetch.JsEnv =
  #| () => {
  #|   const env = Object.create({inherited: 'from prototype'});
  #|   Object.assign(env, {GREETING: 'hello', EMPTY: '', LIMITS: {n: 3}, COUNT: 3,
  #|     BOXED: new String('boxed'), NOTHING: null, KV: {get() {}}});
  #|   Object.defineProperty(env, 'BROKEN', {get() { throw new Error('getter'); }});
  #|   return env;
  #| }

///|
extern "js" fn odd_env(kind : Int32) -> @fetch.JsEnv =
  #| kind => [
  #|   undefined, null, 'GREETING', 42,
  #|   new Proxy({}, {get() { throw new Error('trap'); }}),
  #|   Object.assign(() => {}, {GREETING: 'on a function'}),
  #| ][kind]

///|
test "env_string reads string bindings and nothing else" {
  let env = workers_like_env()
  assert_eq(@fetch.env_string(env, "GREETING"), Some("hello"))
  assert_eq(@fetch.env_string(env, "EMPTY"), Some(""))
  assert_eq(@fetch.env_string(env, "inherited"), Some("from prototype"))
  for
    key in ["LIMITS", "COUNT", "BOXED", "NOTHING", "KV", "MISSING", "toString"] {
    assert_eq(@fetch.env_string(env, key), None)
  }
}

///|
test "env_string returns None instead of raising on odd environments" {
  assert_eq(@fetch.env_string(workers_like_env(), "BROKEN"), None)
  for kind in 0..<5 {
    assert_eq(@fetch.env_string(odd_env(kind), "GREETING"), None)
  }
  assert_eq(@fetch.env_string(odd_env(5), "GREETING"), Some("on a function"))
}
