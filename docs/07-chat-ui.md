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

## 認証と公開範囲

- **アカウント**：自分での登録を無効にし（`ENABLE_SIGNUP=false`）、管理者がアカウントを作る。最初の 1 つだけは登録でき、管理者になる。
- **会話の閲覧**：管理者も利用者の会話を読めないようにした（`ENABLE_ADMIN_CHAT_ACCESS=false`）。
- **モデルの公開**：接続先のモデルは、既定では管理者にしか見えない。利用者は関係者に限られ、モデルも 1 つだけなので、すべての利用者に公開した（`BYPASS_MODEL_ACCESS_CONTROL=true`）。
- **ネットワーク**：Open WebUI は既定で chat ホストの中（`127.0.0.1:3000`）だけで待ち受ける。社外からは ngrok で公開し、ngrok の Basic 認証と Open WebUI のログインの 2 段で守る。spark1 の API（`:8888`）は公開しない。

## 検証結果

Open WebUI `v0.11.4` を、chat ホストで動かす前に作業用のマシン（rootless Docker）で動かし、`127.0.0.1:3000` に公開して確かめた（2026-09-27）。

| # | 検証項目 | 結果 | 判定 |
|---|---|---|---|
| 1 | 接続 | モデル一覧に `deepseek-v4-flash-vision-exp` が出る。「日本の首都を一語で答えて」に「東京」と返り、思考の内容は `reasoning` に分かれて返る | ✅ |
| 2 | アカウント | 最初のアカウントが管理者になる。2 つ目の自己登録は拒否される。管理者から一般ユーザーを追加できる | ✅ |
| 3 | モデルの公開 | `BYPASS_MODEL_ACCESS_CONTROL` がないと、一般ユーザーには `Model not found` になる。設定後は使える | ✅ |
| 4 | 履歴の分離 | ユーザー 1 の会話は、ユーザー 2 の一覧に出ない | ✅ |
| 5 | 履歴の保持 | コンテナを作り直しても、会話履歴とログインのセッションが残る | ✅ |
| 6 | 同時実行数 | 8 本を同時に送ると、vLLM の処理中は最大 6 本、待ちは最大 2 本。8 本とも HTTP 200 で応答し、待った 2 本は約 23〜26 秒、ほかは約 13 秒で返った | ✅ |
| 7 | データの除外 | `data/` と `.env` は `git status` に出ず、除外されている | ✅ |
| 8 | ngrok | chat ホストで確認する | 未実施 |

同時実行数の検証では、spark1 の `/metrics` を 1 秒ごとに読んだ。

```
vllm:num_requests_running=6.0  vllm:num_requests_waiting=2.0   ← 8 本を送った直後
vllm:num_requests_running=4.0  vllm:num_requests_waiting=0.0   ← 最初の 6 本の一部が終わった
vllm:num_requests_running=2.0  vllm:num_requests_waiting=0.0   ← 待っていた 2 本を処理中
```

ブラウザで思考の内容が回答と分けて表示されるかは、画面で確認する `[要検証]`。

## 初回起動時の通信

Open WebUI は初回起動時に、文書検索用の埋め込みモデル（`sentence-transformers/all-MiniLM-L6-v2`）を Hugging Face から取得する。
chat ホストは、初回だけインターネットに出られる必要がある。
取得したモデルは `data/cache/` に保存され、2 回目以降は使い回す。
