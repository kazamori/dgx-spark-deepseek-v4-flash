# 5. 運用

日々の操作は、すべて spark1（ヘッド）のレシピのディレクトリで行う。
ワーカーの操作も、スクリプトが ssh 経由で行う。

```bash
cd ~/work/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark
```

## 基本のコマンド

| 操作 | コマンド | 動き `[出典あり]` |
|---|---|---|
| 起動 | `./start-deepseek-v4-flash-dspark.sh` | `.env.dspark` とパッチをワーカーへ同期し、ワーカー、ヘッドの順に起動する。API が応答するまでログを表示する |
| 停止 | `./stop-deepseek-v4-flash-dspark.sh` | ワーカー、ヘッドの順に停止する。ワーカーに到達できない場合は失敗として報告する |
| 再起動 | `./stop-deepseek-v4-flash-dspark.sh && ./start-deepseek-v4-flash-dspark.sh` | 専用の restart コマンドはない |
| 状態確認 | `./status-deepseek-v4-flash-dspark.sh` | 両機のコンテナ、イメージ ID、ポート、`/v1/models` を確認する。異常があれば `N probe(s) failed` と表示する |
| ログ（直近） | `./logs-deepseek-v4-flash-dspark.sh` | 両機の直近 160 行 |
| ログ（全体） | `TAIL=all ./logs-deepseek-v4-flash-dspark.sh` | 起動時の KV キャッシュの値などを見るとき |
| 疎通確認 | `curl -fsS http://127.0.0.1:8888/v1/models` | 最も軽い死活確認 |

start スクリプトの終了コードは次のとおりである。

- **0**：起動に成功した。
- **3**：すでに起動している。異常ではない。

## 知っておくべき挙動

### マシンを再起動するとコンテナは自動で復帰する

コンテナの再起動ポリシーが `restart: unless-stopped` なので、Docker の起動時にコンテナも立ち上がる `[出典あり]`。
このとき start を実行すると終了コード 3 で終わるが、それで正常である。

ただし、片方だけを再起動した場合は注意が必要である。
レシピの資料に、終了コード 3 は TP グループが健全であることを保証しないこと、ヘッドだけを再起動するとワーカーが古い状態のまま残ることがあると書かれている `[出典あり]`。
片方だけ再起動したあとは、stop、start の順にクラスタ全体を起動し直す。

### `.env.dspark` を変えたら stop、start する

設定は起動時にワーカーへ同期される。
`docker compose restart` では変更が反映されないので使わない `[出典あり]`。

### stop で止めたものは自動で復帰しない

`./stop-…` で止めた場合は、マシンを再起動しても立ち上がらない（`unless-stopped` の仕様どおり）。

### 稼働中は CX-7 のケーブルに触らない

抜き差しすると帯域が大きく落ちることがある。
抜き差しした場合は両機を再起動する。

## 電源の切り方と入れ方

```bash
./stop-deepseek-v4-flash-dspark.sh
ssh spark2 sudo shutdown -h now    # 先にワーカー
sudo shutdown -h now               # 次にヘッド
```

電源を入れるときは両機を起動し、両方が立ち上がってから `./status-…` で状態を確認する。
自動で復帰していなければ `./start-…` を実行する。

## API のエンドポイント

vLLM は OpenAI 互換の API を `:8888` で提供する。
起動ログに出るエンドポイントのうち、利用者に関係する主なものは次のとおりである。

| メソッド | パス | 用途 |
|---|---|---|
| GET | `/v1/models` | 提供しているモデルの一覧 |
| POST | `/v1/chat/completions` | チャット形式の生成（OpenAI 互換） |
| POST | `/v1/completions` | テキスト補完（OpenAI 互換） |
| POST | `/v1/responses` | Responses API（OpenAI 互換） |
| POST | `/v1/messages` | Messages API（Anthropic 互換） |
| GET | `/health` | ヘルスチェック |
| GET | `/metrics` | Prometheus 形式のメトリクス |

クライアントは `model` に `deepseek-v4-flash-vision-exp` を指定する。
別のマシンからは `http://192.168.160.37:8888/v1` を使う（`VLLM_HOST=0.0.0.0` の場合）。
認証なしで公開される点は「[LLM の構築](04-llm-deploy.md#vllm_host-についての注意)」を参照する。

## 補足

- `newgrp docker` は今のシェルでしか有効でない。一度ログインし直せば、以降は恒久的に反映される。
- 手動での運用を前提にしている。常時稼働させる場合は systemd のユニットにすると管理しやすい。その場合は `SuccessExitStatus=3` を指定する `[出典あり]`。
- `./start-… --host 127.0.0.1 --port 9000` のように、その起動だけホストとポートを変えられる。
- earlyoom は両機で無効にしておく（レシピの指示）。
