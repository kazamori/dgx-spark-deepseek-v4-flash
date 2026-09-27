# Open WebUI

spark1 の vLLM（OpenAI 互換 API）に接続するチャット UI として、[Open WebUI](https://github.com/open-webui/open-webui) を動かすための設定である。
複数人でのチャット、利用者ごとの会話履歴の記録と再開ができる。
構成と検証結果は「[チャット UI（Open WebUI）](../../docs/07-chat-ui.md)」を参照する。

spark1 ではなく、社内 LAN にある別の常時稼働マシン（以下 chat ホスト）で動かす。
spark1 の統合メモリを vLLM と取り合わないようにするためである。

## ファイル

設定、データベース、環境変数は、すべてこのディレクトリの下に置く。

| パス | 内容 | コミット |
|---|---|---|
| `compose.yaml` | コンテナの定義 | する |
| `.env.example` | 設定の例 | する |
| `ngrok-policy.example.yaml` | ngrok の認証設定の例 | する |
| `.env` | 実際の設定（`WEBUI_SECRET_KEY` を含む） | しない |
| `ngrok-policy.yaml` | 実際の ngrok の認証設定 | しない |
| `data/` | アカウント、会話履歴（SQLite の `webui.db`）、アップロード、キャッシュ | しない |

コミットしないファイルは [.gitignore](.gitignore) で除外している。
`data/` には利用者の会話内容とパスワードのハッシュが入るので、扱いに注意する。

## 前提

- Docker と Docker Compose が使える。
- chat ホストから spark1 の API（`http://192.168.160.37:8888/v1`）に届く。
- インターネットに出られる。初回起動時に文書検索用の埋め込みモデルを Hugging Face から取得し、Web 検索では検索サービスと各サイトにアクセスする。

## 初回の起動

```bash
cd app/open-webui
cp .env.example .env
sed -i "s/^WEBUI_SECRET_KEY=$/WEBUI_SECRET_KEY=$(openssl rand -hex 32)/" .env
chmod 600 .env
mkdir -p data && chmod 700 data

docker compose up -d
docker compose ps          # STATUS が healthy になるまで待つ（初回は数分かかる）
```

既定では chat ホストの中（`http://127.0.0.1:3000`）からだけ接続できる。
社内 LAN のほかのマシンから使う場合は、`.env` で `OPEN_WEBUI_BIND=0.0.0.0` にして `docker compose up -d` し直す。

コンテナは root（UID 0）で動くので、rootful の Docker では `data/` の中のファイルが root の所有になる。
その場合、バックアップや削除には sudo が要る。
rootless の Docker では、Docker を動かしているユーザーの所有になる。

## アカウントの作成

1. ブラウザで Open WebUI を開き、最初のアカウントを登録する。最初のアカウントは管理者になる。
   `ENABLE_SIGNUP=false` でも、最初の 1 つだけは登録できる。
2. 2 つ目以降のアカウントは、管理者が管理画面（Admin Panel の Users）から作る。自分で登録することはできない。

ngrok で公開する前に、管理者アカウントを作っておく。
管理者アカウントを作る前に公開すると、第三者が最初のアカウント（管理者）を登録できてしまう。

## 設定の変更

`.env` の設定の多くは、初回起動時にデータベースへ保存され、以後はデータベースの値が優先される（Open WebUI の PersistentConfig）。
初回起動後に接続先の URL などを変えるときは、`.env` ではなく管理画面（Admin Panel の Settings）で変更する。

次の設定はデータベースに保存されないので、`.env` を変えて `docker compose up -d` すれば反映される。

- `WEBUI_AUTH`、`WEBUI_SECRET_KEY`
- `ENABLE_ADMIN_CHAT_ACCESS`（管理者が利用者の会話を閲覧できるか。`false` にしている）
- `BYPASS_MODEL_ACCESS_CONTROL`（すべての利用者にモデルを公開するか。`true` にしている）
- `OPEN_WEBUI_BIND`、`OPEN_WEBUI_PORT`

## Web 検索の検索エンジン

既定は API キーが要らない DuckDuckGo である。
ほかの検索エンジンを使うときは、初回起動の前なら `.env` の `WEB_SEARCH_ENGINE` と API キーの欄（`BRAVE_SEARCH_API_KEY`、`TAVILY_API_KEY` など）を設定する。
初回起動後は、管理画面（Admin Panel の Settings、Web Search）で変更する。
API キーは `.env` か管理画面にだけ置き、リポジトリには書かない。

## 停止と再起動

```bash
docker compose stop        # 停止
docker compose up -d       # 起動（設定を変えたときも同じ）
docker compose logs -f     # ログ
```

コンテナを作り直しても、`data/` と `.env` が残っていれば、アカウント、会話履歴、ログインのセッションは残る。

## バックアップ

コンテナを止めてから `data/` をコピーする。

```bash
docker compose stop
tar czf open-webui-data-$(date +%Y%m%d).tar.gz data .env
docker compose up -d
```

バックアップのファイルにも会話内容と `WEBUI_SECRET_KEY` が含まれるので、リポジトリの外の安全な場所に置く。

## ngrok での公開

社外の同僚に使ってもらうときは、chat ホストの中から ngrok で Open WebUI だけを公開する。
spark1 の API（`:8888`）は認証がないので、ngrok で公開しない。

Open WebUI のログインの前に、ngrok の [Traffic Policy](https://ngrok.com/docs/traffic-policy/) で Basic 認証をかける。

```bash
cp ngrok-policy.example.yaml ngrok-policy.yaml
chmod 600 ngrok-policy.yaml
# ngrok-policy.yaml の USERNAME:PASSWORD を書き換える
ngrok http 3000 --traffic-policy-file=ngrok-policy.yaml
```

Basic 認証の代わりに、[OAuth](https://ngrok.com/docs/traffic-policy/actions/oauth)（Google アカウントなど）で利用者を限定することもできる。
使える機能は ngrok のプランによって変わる。
ngrok の URL、authtoken、認証情報は、リポジトリにも issue にも書かない。

## ライセンス

Open WebUI は [Open WebUI License](https://github.com/open-webui/open-webui/blob/main/LICENSE) で公開されている。
このライセンスは、利用者が 30 日間で 50 人を超える場合などに、「Open WebUI」の名前やロゴの変更を禁じている。
この設定は公式のイメージをそのまま使い、表示は変えない。
