# 7. チャット UI（Open WebUI）

spark1 の vLLM を複数人で使うためのチャット UI として、[Open WebUI](https://github.com/open-webui/open-webui) を動かす。
起動と運用の手順は [app/open-webui/README.md](../app/open-webui/README.md) にまとめた。

## 要件と方針

| 要件 | 方法 |
|---|---|
| 複数人が同時にチャットできる | Open WebUI のアカウント管理を使う。アカウントは管理者が作る |
| 利用者ごとに会話履歴を記録、参照、再開できる | Open WebUI が会話を SQLite（`app/open-webui/data/webui.db`）に保存する |
| 同時に処理するリクエスト数を制限し、超えた分は待たせる | 当面は vLLM の `--max-num-seqs`（6）に任せる |
| 社外の同僚に ngrok 経由で使ってもらう | Open WebUI だけを ngrok で公開し、ngrok でも Basic 認証をかける |

Open WebUI は spark1 ではなく、社内 LAN にある別のマシン（chat ホスト）で動かす。
spark1 の統合メモリは大半を vLLM が使っているためである。

![システム構成図](../diagrams/system-architecture.png)

利用者のリクエストは、ブラウザから Open WebUI を経由して spark1 の API に届く。
Open WebUI から先の処理の流れは、「[LLM の構築](04-llm-deploy.md#リクエストが処理される流れ)」の流れ図と同じである。

## 同時実行数の制限

vLLM は、同時に処理するリクエストを `--max-num-seqs`（レシピの既定は 6）までに制限する。
それを超えたリクエストはエラーにならず、vLLM の中で順番を待つ。
上限は全利用者の合計であり、値を変えるには `.env.dspark` の `MAX_NUM_SEQS` を書き換えて vLLM を再起動する（「[運用](05-operations.md)」を参照）。

待っている間も Open WebUI 側のタイムアウトは進む。
Open WebUI から vLLM への接続のタイムアウト（`AIOHTTP_CLIENT_TIMEOUT`）は既定で無制限なので、既定のままにしている。

Open WebUI は、会話のたびにタイトルやタグなどを LLM で生成する。
これらも同じ vLLM に送られて 6 本の枠を使うので、タイトル生成だけを残し、ほかは無効にした。

| 設定 | 値 |
|---|---|
| `ENABLE_TITLE_GENERATION` | `true` |
| `ENABLE_TAGS_GENERATION`、`ENABLE_FOLLOW_UP_GENERATION`、`ENABLE_AUTOCOMPLETE_GENERATION` | `false` |
| `ENABLE_SEARCH_QUERY_GENERATION`、`ENABLE_RETRIEVAL_QUERY_GENERATION` | `false` |

## Web 検索

チャットから Web 検索を使えるようにした。
既定の検索エンジンは、API キーが要らない DuckDuckGo である。
ほかの検索エンジン（Brave、Tavily、Serper、Google PSE、SearXNG など）を使う場合は、`.env` の `WEB_SEARCH_ENGINE` を変え、対応する API キーを設定する（初回起動後は管理画面の Web Search で変更する）。

| 設定 | 値 | 理由 |
|---|---|---|
| `ENABLE_WEB_SEARCH` | `true` | Web 検索を使えるようにする |
| `WEB_SEARCH_ENGINE` | `duckduckgo` | API キーが要らない |
| `WEB_SEARCH_RESULT_COUNT` | `3` | 入力トークンを増やしすぎない |
| `BYPASS_WEB_SEARCH_WEB_LOADER` | `true` | 検索結果のページを取得せず、要約文だけを使う（下の測定結果を参照） |
| `DEFAULT_MODEL_METADATA` | `defaultFeatureIds` に `web_search` | 新しい会話で Web 検索を最初からオンにする |

新しい会話では、Web 検索が最初からオンになっている（`DEFAULT_MODEL_METADATA` の `defaultFeatureIds` に `web_search` を指定）。
利用者は会話ごとに入力欄のメニューからオフにできる。
Web 検索がオンのとき、モデルに検索ツール（`search_web`）とページ取得ツール（`fetch_url`）が渡される。
Open WebUI `v0.11.4` の既定（ネイティブのツール呼び出し）では、検索するか、どのページを読むかをモデル自身が判断する。
spark1 の vLLM はツール呼び出しを有効にして起動しているので（`--enable-auto-tool-choice --tool-call-parser deepseek_v4`）、この方式がそのまま動く。

検索エンジンの選択にあたり、検索結果の処理方法ごとに、検索 1 回（DuckDuckGo、結果 3 件）にかかる時間を測った。

| 処理方法 | 所要時間（4 回） |
|---|---|
| 要約文だけを使う（`BYPASS_WEB_SEARCH_WEB_LOADER=true`） | 1.9〜4.3 秒 |
| ページを取得し、そのまま使う | 2.1〜5.0 秒 |
| ページを取得し、埋め込みで絞り込む（Open WebUI の既定） | 3.6〜7.3 秒、1 回は 303 秒 |

所要時間の大半は DuckDuckGo の検索である。
ページを取得する方式では、応答の遅いサイトに当たると大きく待たされることがある `[推定]`。
そのため要約文だけを使う設定にし、ページの本文が必要なときはモデルが `fetch_url` で読む形にした。

実際に「Open WebUI の最新リリースのバージョン番号を Web で調べて教えて」と送ると、モデルは `search_web` で検索し、`fetch_url` で GitHub のリリースページを読んで、「v0.11.4」と出典付きで答えた。
LLM の呼び出し 3 回とツールの実行 2 回を含めて、約 28 秒かかった。

Web 検索を使うと、利用者の質問が検索語として外部の検索サービスに送られる。
また、検索とページの取得のたびに LLM の呼び出しが増え、spark1 の同時実行数の枠を使う。

## 認証と公開範囲

- **アカウント**：自分での登録を無効にし（`ENABLE_SIGNUP=false`）、管理者がアカウントを作る。最初の 1 つだけは登録でき、管理者になる。
- **会話の閲覧**：管理者も利用者の会話を読めないようにした（`ENABLE_ADMIN_CHAT_ACCESS=false`）。
- **モデルの公開**：接続先のモデルは、既定では管理者にしか見えない。利用者は関係者に限られ、モデルも 1 つだけなので、すべての利用者に公開した（`BYPASS_MODEL_ACCESS_CONTROL=true`）。
- **ネットワーク**：Open WebUI は既定で chat ホストの中（`127.0.0.1:3000`）だけで待ち受ける。社外からは ngrok で公開し、ngrok の Basic 認証と Open WebUI のログインの 2 段で守る。spark1 の API（`:8888`）は公開しない。

## 検証結果

Open WebUI `v0.11.4` を、chat ホストで動かす前に作業用のマシン（rootless Docker）で動かし、`127.0.0.1:3000` に公開して確かめた（2026-09-27）。
9 の ngrok だけは、chat ホストで確かめた。

| # | 検証項目 | 結果 | 判定 |
|---|---|---|---|
| 1 | 接続 | モデル一覧に `deepseek-v4-flash-vision-exp` が出る。「日本の首都を一語で答えて」に「東京」と返り、思考の内容は `reasoning` に分かれて返る。ブラウザでも、思考の内容は回答と分けて表示される | ✅ |
| 2 | アカウント | 最初のアカウントが管理者になる。2 つ目の自己登録は拒否される。管理者から一般ユーザーを追加できる | ✅ |
| 3 | モデルの公開 | `BYPASS_MODEL_ACCESS_CONTROL` がないと、一般ユーザーには `Model not found` になる。設定後は使える | ✅ |
| 4 | 履歴の分離 | ユーザー 1 の会話は、ユーザー 2 の一覧に出ない | ✅ |
| 5 | 履歴の保持 | コンテナを作り直しても、会話履歴とログインのセッションが残る | ✅ |
| 6 | 同時実行数 | 8 本を同時に送ると、vLLM の処理中は最大 6 本、待ちは最大 2 本。8 本とも HTTP 200 で応答し、待った 2 本は約 23〜26 秒、ほかは約 13 秒で返った | ✅ |
| 7 | データの除外 | `data/` と `.env` は `git status` に出ず、除外されている | ✅ |
| 8 | Web 検索 | モデルが `search_web` と `fetch_url` を呼び、出典付きで答えた（約 28 秒） | ✅ |
| 9 | ngrok | chat ホストで動かし、ngrok 経由で利用できた | ✅ |

同時実行数の検証では、spark1 の `/metrics` を 1 秒ごとに読んだ。

```
vllm:num_requests_running=6.0  vllm:num_requests_waiting=2.0   ← 8 本を送った直後
vllm:num_requests_running=4.0  vllm:num_requests_waiting=0.0   ← 最初の 6 本の一部が終わった
vllm:num_requests_running=2.0  vllm:num_requests_waiting=0.0   ← 待っていた 2 本を処理中
```


## 初回起動時の通信

Open WebUI は初回起動時に、文書検索用の埋め込みモデル（`sentence-transformers/all-MiniLM-L6-v2`）を Hugging Face から取得する。
Web 検索を使うので、chat ホストはインターネットに出られる必要がある。
取得したモデルは `data/cache/` に保存され、2 回目以降は使い回す。
