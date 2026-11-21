# mttp

[![CI](https://github.com/gaato/mttp/actions/workflows/ci.yml/badge.svg)](https://github.com/gaato/mttp/actions/workflows/ci.yml)
[![Ask DeepWiki](https://img.shields.io/badge/Ask-DeepWiki-blue)](https://deepwiki.com/gaato/mttp)
[![License](https://img.shields.io/github/license/gaato/mttp)](LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-gaato%2Fmttp-blue)](https://mooncakes.io/docs/gaato/mttp)
[![MoonBit 0.10.22+124d61d05](https://img.shields.io/badge/MoonBit-0.10.22%2B124d61d05-blue)](https://www.moonbitlang.com)

[MoonBit](https://www.moonbitlang.com/) の HTTP です。クライアント、サーバー、WebSocket を native・wasm・JS ホストで使えます。一つのエンドポイント定義が、そのままハンドラーにも型付きクライアントにも OpenAPI 文書にもなります。全体を外部のテストスイートで照合し、プロトコルの読み取り部をファジングし、HTTP/1 の数値の中核を証明しています。

[gaato/mttp](https://mooncakes.io/docs/gaato/mttp) · [gaato/mttp_core](https://mooncakes.io/docs/gaato/mttp_core) · [例](#例) · [バックエンドの契約](CONTRACT.md) · [English](README.md)

## 始める

アプリが足すモジュールは一つです:

```sh
moon add gaato/mttp
```

パッケージでは `"gaato/mttp"` を import します。次は [examples/get](examples/get) で、再試行・時間制限・リダイレクト・展開を有効にして GET を一回送ります。native・wasm・js で動きます:

<!-- source: examples/get/main.mbt -->
```moonbit
///|
fn main {
  @mttp.run(async fn() {
    let client = @mttp.client()
    defer client.close()
    let reply = client.send(@mttp.get("https://example.com/"))
    match reply.body {
      Ok(text) => println("\{reply.status}: \{text.length()} characters")
      Err(failure) => println("\{reply.status}: \{failure}")
    }
  })
}
```

ハンドラーは `gaato/mttp/server` で公開します。次は [examples/serve](examples/serve) で、`moon run examples/serve -- 127.0.0.1:8080` で動きます:

<!-- source: examples/serve/main.mbt -->
```moonbit
///|
async fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    println("usage: serve <address>")
    @env.exit(2)
  }
  @server.serve(
    _ => @mttp.Response::new(200, body=Bytes(b"hello\n")),
    addr=args[1],
    on_listen=addr => println("listening on \{addr}"),
  )
}
```

型付きエンドポイント・OpenAPI 文書・テストが揃った状態でサービスを始めるなら、[templates](templates) のどちらかを写してください。native の API サーバーと、Cloudflare Workers のアプリがあります。

## 一つの定義を三通りに使う

型付きエンドポイントは、mttp のモジュール群のうち I/O を持たない `gaato/mttp_core` にあります。定義を wasm-gc でビルドするコードとも共有できるようにするためです。使うアプリは gaato/mttp の隣に足します(`moon add gaato/mttp_core`):

<!-- source: examples/tour/main.mbt -->
```moonbit
///|
fn main {
  // Define it: GET /hello/{name} takes a String from the path, answers text.
  let hello = @endpoint.endpoint
    .get("/hello/{name}")
    .input(@endpoint.path("name", @schema.string))
    .output(@endpoint.text_out())
    .operation_id("hello")

  // Implement it. The clock and timer let the Router keep the client's
  // deadlines when it answers in-process, as below.
  let app = @router.Router::must(
    [hello.serve_public(name => Ok("hello, \{name}"))],
    clock=@mttp.clock(),
    timer=@mttp.timer(),
  )

  @mttp.run(async fn() {
    // Serve it on a port: `moon run examples/tour -- 127.0.0.1:8080`.
    if @env.args() is [_, addr] {
      @server.serve(app.handler(), addr~)
      return
    }

    // Call it with the typed client: a String goes in, a String comes back.
    // The Router is a Backend too, so here it answers without a port.
    let client = @mttp.client(backend=app)
    defer client.close()
    match hello.request((), "moon").send(client).body {
      Ok(Ok(greeting)) => println(greeting)
      _ => println("the call failed")
    }

    // Document it: the OpenAPI 3.1 document of the same definition.
    let spec = @openapi.to_openapi(
      [hello.doc()],
      @apispec.Info::new("Hello", "1.0.0"),
    )
    println(spec.to_json().stringify(indent=2))
  })
}
```

文書を配信するには、ルーターのエンドポイントに `@openapi.docs_endpoint(spec)` と `@openapi.docs_ui_endpoint(spec_url="/openapi.json")` を加えます。`/docs` の既定は Scalar で、`ui=SwaggerUi` を渡すと Swagger UI になります。ページの CSP のもとでは、仕様を同じオリジンに置く必要があります。SSE の `itemSchema` を含む OpenAPI 3.2.0 を出すには、`to_openapi` に `version=V3_2` を渡します。クライアント生成器との互換のため、既定は 3.1.0 のままです。

clone した中で `moon run examples/tour` を実行すると、挨拶と文書が出ます。文書にはパスパラメーター、テキストの応答、そして不正なリクエストにルーターが返す problem 応答が載ります:

<!-- excerpt: examples/tour -->
```text
hello, moon
{
  "info": {
    "title": "Hello",
    "version": "1.0.0"
  },
  "paths": {
    "/hello/{name}": {
      "get": {
        "responses": {
          "200": {
            "description": "OK",
            "content": {
              "text/plain": {
                "schema": {
                  "type": "string"
                }
              }
            }
          },
          "400": {
            "description": "Bad Request",
            ...
        "operationId": "hello",
        "parameters": [
          {
            "name": "name",
            "in": "path",
            "required": true,
            "schema": {
              "type": "string"
            }
          }
        ],
        "security": []
      }
    }
  },
  "openapi": "3.1.0",
  ...
}
```

## 見える再試行

[examples/retries](examples/retries) は、2 回 503 を返してから 200 を返すサーバーを手元のポートで立て、`@mttp.client()` が既定で使う再試行の方針と予算で呼び出し、試行ごとに表示します:

<!-- output: examples/retries -->
```text
attempt 1: 503, retry in 500 ms
attempt 2: 503, retry in 1000 ms
attempt 3: 200, done
result: 200 ready
```

待ち時間は 500 ms から倍になっていきます。クライアントどうしが揃って再試行しないよう、待ち時間は普段は前後 20 % までばらつきます。この例はばらつきを真ん中に固定しているので、毎回同じ表示になります。GET が再試行されるのは冪等だからで、POST は送られていなかったとき、または呼び出し側が再送してよいと示したときだけ再試行されます。

## `moonbitlang/core/async/http` との違い

クライアントとサーバーの、コンパイルが通る移行前後の例は [MIGRATING.md](MIGRATING.md) にあります。`moonbitlang/async/http` からの移行も含みます。

単純な GET なら標準ライブラリで足ります。`@http.get(url)` は依存を足さずに応答のヘッダーと本文を返します。mttp は、その呼び出しの周りに増えていくもののためにあります:

| | `moonbitlang/core/async/http` | mttp |
|---|---|---|
| 再試行・時間制限・流量 | 呼び出しを `@async.with_timeout` で包む。再試行や流量の方針はない | 予算つきの再試行と、30 s / 120 s の時間制限が既定。ウィンドウ・ペース・ヘッダーに従う流量制限を選んで使える |
| リダイレクト | native と wasm では追わない。js ではホストの `fetch` が追う | 最大 10 回。HTTPS から HTTP へは移らず、オリジンをまたぐと資格情報を落とす |
| Cookie | native/wasm で `Set-Cookie` を解析する。jar はない | RFC 6265 の jar(`cookies=`)。リダイレクトの各段で適用する |
| 内容のコーディング | native と wasm で gzip の応答を展開する。サーバー側とリクエストの圧縮はない | gzip・deflate・br・zstd を両方向に。クライアントの展開、サーバーの `compress`、選んで使うリクエスト本文の圧縮。RFC 9842 の辞書(`dcb`、`dcz`) |
| 接続の再利用 | `Client` はリクエストごとに接続を開く | Client ごとに接続をプールする |
| 型付きの失敗 | エラーを送出する。404 は普通の応答 | HTTP とデコードの失敗は `reply.body` に入る。`TransportError` は段階と送信済みかを示す |
| 型付きエンドポイントと OpenAPI | ない | 一つの定義からハンドラー・クライアント・OpenAPI 3.1 または 3.2。構造の互換性の差分 |
| サーバー | native と wasm で HTTP/1.1。接続にヘッダーと本文を書く | native/wasm のエンジンは HTTP/1.1。JS の fetch/サーバーはホストが交渉した版。HTTP/2 エンジンは core/tls の ALPN 待ち。上限つきの `Request -> Response` ハンドラー、穏当な停止 |
| WebSocket | 別の `core/async/websocket`。native/wasm でクライアントとサーバー。拡張なし | クライアントとサーバー。native/wasm で選んで使う permessage-deflate。両方向で Autobahn。JS ホストのセッション |
| サーバーのミドルウェア | 方針の層はない | RateLimit ヘッダーつきの `rate_limit`、`secure_headers`、署名つき Cookie のセッション、CORS |
| 表現 | 生のヘッダーと本文。選択やファイルのハンドラーはない | Accept の交渉と 406。条件付きの 304/412。静的ファイルと、選んで使う Range の 206/416 |
| 私的な HTTP キャッシュ | キャッシュの方針はない。JS の fetch はホスト任せ | 選んで使う RFC 9111 キャッシュ: Vary、検証子、資格情報ごとの区画、上限つきのメモリ |
| 回復と観測 | 回復の方針もクライアントのイベントもない | サーキットブレーカー、資格情報の更新、SSE の再接続。クライアントのイベントと W3C trace context |
| ネットワークなしのテスト | 差し替えられるバックエンドはない | 関数のバックエンド、`BackendStub`、Router、仮想時計 |
| wasm-gc | 不可。native・wasm・js | `gaato/mttp_core` のすべて。I/O は実行環境のポートを用意する |

js ではどちらのクライアントもホストの `fetch` で送り、展開と接続の再利用は `fetch` 自身が行います。それでも mttp の Client はリダイレクトを上の規則で追います。mttp は Cloudflare Workers・Deno・Bun・Node・Fastly・Vercel・AWS Lambda 向けのハンドラーを書き出せます。WebSocket のアップグレードは Workers・Deno・Bun で使えます。[ホストの対応表](mttp/hosts/README.md#websockets)を参照してください。標準ライブラリの列は、[moonbit-version](moonbit-version) が固定するツールチェーンのもので、別の WebSocket パッケージも含みます。

## モジュール

| モジュール | 足すのは |
|---|---|
| [`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp) | アプリやサーバーを作るとき。上の既定値でネットワークにリクエストを送り、ハンドラーを公開し、アプリが使う型・リクエスト属性・クライアント関数を再公開する。型付きエンドポイント・ルーター・OpenAPI 文書・multipart 本文・流量制限・テスト用スタブには、隣に `gaato/mttp_core` を足す。 |
| [`gaato/mttp_core`](https://mooncakes.io/docs/gaato/mttp_core) | ある API の SDK のようなライブラリを書くとき。`Client` を受け取り、ネットワークはアプリに任せるので、wasm-gc を含むすべてのターゲットでビルドでき、テストもネットワークなしで動く。 |
| [`gaato/mttp_digest`](https://mooncakes.io/docs/gaato/mttp_digest) | サーバーが HTTP Digest 認証を求めるとき。 |
| [`gaato/mttp_schemagen`](https://mooncakes.io/docs/gaato/mttp_schemagen) | 注釈を付けた MoonBit の型から JSON のコーデックとスキーマを生成したいとき。`moonx` で動かすコマンドラインの生成器で、生成したコードは `gaato/mttp_core` を使う。 |

`gaato/mttp_core` は I/O を持たない部分すべてで、どのターゲットでもビルドできます。`gaato/mttp` はそれを `moonbitlang/core/async` でネットワークにつなぎます。`gaato/mttp_digest` はどちらにも Digest 認証を足し、`gaato/mttp_schemagen` はどちらのスキーマにもコーデックを書きます。この分け方は Scala の [sttp](https://sttp.softwaremill.com/) のモジュール群にならっています。

探すとよいパッケージ(注記のない限り `gaato/mttp_core` の下):

- `ws`: どこでも動く WebSocket のセッションとコーデック。`gaato/mttp/ws` が permessage-deflate つきで接続とアップグレードを行います。
- `client/httpcache`: 選んで使う私的な HTTP キャッシュ。
- `representation`: 内容の交渉、検証子、事前条件、バイト範囲。`gaato/mttp/files` がファイルに適用します。
- `apispec/diff`: クライアントとサーバーのための、OpenAPI の構造の互換性の報告。
- `multipart`: ストリームで書き、上限つきで読む form-data。型付きエンドポイントの入力でも使います。
- `router`: 振り分けとミドルウェア。流量制限、セキュリティヘッダー、署名つき Cookie のセッションを含みます。

### 例

- [examples/tour](examples/tour): 上のエンドポイントを公開し、呼び出し、文書にします。
- [examples/retries](examples/retries): 上の再試行。
- [examples/get](examples/get): GET を一回送ります。native・wasm・js で動きます。
- [examples/serve](examples/serve): 上のサーバー。
- [examples/fetch](examples/fetch): JavaScript ホスト向けの `fetch` エクスポートと、[Cloudflare Workers のアプリ](examples/fetch/workers)。

## どう確かめているか

push とプルリクエストごとに、[`scripts/gates.sh full`](scripts/gates.sh) が、対応するすべてのターゲット、文書と台帳、そして本物の workerd 上の Workers の例を確かめます。毎日の canary が最新と nightly のツールチェーンで同じことを繰り返し、ツールチェーンを固定した別のジョブが相互運用・サニタイザー・ファジング・ベンチマークを回します。ミューテーションテストと証明は手動のゲートです。

- I/O を持たないモジュール、`gaato/mttp_core` と `gaato/mttp_digest` は、wasm-gc・wasm・js・native で同じテストを回します。[scripts/test_manifest.tsv](scripts/test_manifest.tsv) が各パッケージの各ターゲットでのテスト数を記録し、数が記録なしに変わったり、ターゲット間で違ったりするとゲートが落ちます。
- [conformance](conformance) は、URL の解析を WHATWG URL のテストベクターで、フォームと Cookie を WPT と http-state のデータで、HTTP/1 のコーデックを llhttp のテストと WPT の応答解析の表で、四つのターゲットすべてで照合します。
- [RESOURCE_BOUNDS.md](RESOURCE_BOUNDS.md) は、ネットワークからの入力やリクエスト数に応じて育つ構造をすべて、その上限と、上限を超えさせるテストとともに挙げています。
- [SECURITY_CLASSES.md](SECURITY_CLASSES.md) は、HTTP の脆弱性の分類ごとに、mttp を守る回帰テスト、または残る機能の穴を閉じる予定の作業を対応づけています。
- [CONTRACT.md](CONTRACT.md) は、バックエンド・実行環境のアダプター・テストダブルが守るべきことを定めています。同じ契約の検査を、メモリ内のダブルと `gaato/mttp` のアダプターの両方に対して回します。
- [TEST_COVERAGE.md](TEST_COVERAGE.md) は、テストが通らない行すべてに理由を付けています。
- この README のコードと出力は例そのもので、[scripts/readme_check.mbtx](scripts/readme_check.mbtx) が照合します。
- 毎日、`gaato/mttp_core` と `gaato/mttp` の native のテストを、リンクする C ごと AddressSanitizer のもとで回します(`scripts/gates.sh sanitize`)。
- [相互運用のスイート](interop)は、クライアントを nginx・Caddy・Apache と、サーバーを curl・Go・httpx・Node・Bun・Deno と、直接とリバースプロキシ越しに照合します。Http11Probe がプロトコルへの準拠を探り、Schemathesis が型付きエンドポイントをその OpenAPI 文書と照合します。[HTTP Garden](interop/README.md#http-garden) には手動の差分テスト用アダプターがあります。
- Autobahn が WebSocket を permessage-deflate を含めて両方向で確かめます。[記録した native クライアントの実行](interop/README.md)は、合格 460、既知の判定と完全に一致するもの 57、想定外の失敗 0 です。両方向の既知の圧縮のケースは、エンコードのウィンドウを 15 ビットに固定していることによるものです。スイートの生の判定は FAILED も含めてそのまま見えるようにしており、合格に書き換えてはいません。
- [カバレッジ誘導のファジング](fuzz)が、HTTP/1 の読み取り部と WebSocket のフレーム解析を libFuzzer と AddressSanitizer で回します。手動の [ミューテーションのサンプル](scripts/mutate.mbtx)は HTTP/1 のフレーミングの回帰を確かめます。
- Z3 と CVC5 による [証明](mttp_core/src/h1/PROOFS.md)は、Content-Length とチャンクサイズに使う整数の中核を、桁あふれの拒否を含めて扱います。文字列、バイトの変換、その他のフレーミングは、証明の外にあるテスト済みの統合コードです。
- [転送のベンチマーク](benchmarks/README.md)は、固定したループバックの負荷で mttp を core/async/http・Go・Node と比べます。CI は毎日の表を成果物として記録しますが、性能を合否の閾値にはしていません(`scripts/gates.sh bench`)。

## 状態

mttp が native と wasm で動かすエンジンは HTTP/1.1 を話します。JS ホストでは、ホストの fetch とサーバーが交渉した版を使います。HTTP/2 エンジンは core/tls の ALPN を待っています。

モジュールは 0.x で、マイナーリリース(0.1 → 0.2)は API を壊すことがありますが、パッチリリースは壊しません。何が変わり何を改名するかは、[mttp/CHANGELOG.md](mttp/CHANGELOG.md) のような各モジュールの変更履歴にあります。不具合と予定の作業は [Issues](https://github.com/gaato/mttp/issues) で追っています。

実験的なパッケージが一つあります。テストで `run_sync` を支える決定的なタスクドライバー `gaato/mttp_core/driver` で、変わりうるコンパイラーの組み込みに頼っているためです。これを import するパッケージは、`moon.pkg` に次を書きます: `options("allow-experimental-packages": [ "gaato/mttp_core/driver" ])`。

`gaato/mttp` は、ツールチェーンがまだ実験的としている `moonbitlang/core/async` の上で動きます。その `run` と `client()` があるので、アプリの `moon.pkg` にその宣言は要りません。タスクを生み出すためなど、core/async を自分で import するコードは宣言します。ゲートは [moonbit-version](moonbit-version) が固定するツールチェーンで回ります。

## ライセンス

Apache-2.0 です。[LICENSE](LICENSE) と [NOTICE](NOTICE) を参照してください。
