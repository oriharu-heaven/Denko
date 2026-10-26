# Denko 連携ガイド

Denko は、この Mac の中から送られたお知らせを掲示板に流せます。
コーディングエージェント、スクリプト、ショートカットなど、HTTP を送れるものなら何でもつなげられます。

- 受け付けるのは **この Mac の中からだけ**（`127.0.0.1`）です。ほかのパソコンやインターネットからは届きません。
- URL には推測できないトークンが入っています。ブラウザで開いたページなどからは送れません。

## 受け付け用の URL

**設定 → 連携 →「受け付け用の URL をコピー」** でコピーできます。形は次のとおりです。

```
http://127.0.0.1:47326/notify/<トークン>
```

以下の例では、これを `$DENKO` と書きます。

```bash
export DENKO='http://127.0.0.1:47326/notify/<トークン>'
```

## 基本の送り方

```bash
curl -s -X POST "$DENKO?title=ビルドが終わりました"
```

| パラメータ | 意味 |
|---|---|
| `title` | 掲示板に流す文（必須。本文だけ送った場合はそれが使われます） |
| `body` | 続けて流す補足 |
| `url` | 「最近のお知らせ」から開くリンク |
| `priority=high` | 緊急として流す（設定 → 掲示板 →「Webhook・スクリプトから」が「ふつう」のとき） |

JSON でも送れます。

```bash
curl -s -X POST "$DENKO" -H 'Content-Type: application/json' \
  -d '{"title":"デプロイ完了","body":"本番 v1.2.0","url":"https://example.com"}'
```

<a id="coding-agents"></a>
## コーディングエージェント

許可待ち・入力待ちと作業完了を、エージェントの種類に関係なく同じように扱います。
どちらをどう流すか（緊急／ふつう／流さない）は **設定 → 掲示板 → お知らせの種類ごとの流し方** で選べます。

### Claude Code（自動で設定できます）

**設定 → 連携 → Claude Code →「連携する…」** を押すと、`~/.claude/settings.json` にフックを追加します。
`Notification`（許可待ち・入力待ち）と `Stop`（応答完了）が届くようになります。変更前にバックアップを作ります。

### Codex（自動で設定できます）

**設定 → 連携 → Codex →「連携する…」** を押すと、`~/.codex/config.toml` の先頭に次の 1 行を追加します。

```toml
notify = ["curl", "-s", "-m", "2", "-X", "POST", "http://127.0.0.1:47326/notify/<トークン>?source=codex", "--data-binary"]
```

Codex は作業が終わるたびに、この末尾に JSON を付けて実行します。
すでに別の `notify` を設定している場合、Denko は上書きしません。自分のスクリプトの中から次の「そのほかのエージェント」の形で送ってください。

### そのほかのエージェント（Gemini CLI・Antigravity・Cursor など）

どのツールでも、フック・通知コマンド・タスクの完了時に実行するコマンドなどから、次の形で送れます。

```bash
# 作業完了
curl -s -X POST "$DENKO?source=agent&agent=Gemini&event=done&project=$PWD"
# 許可待ち・入力待ち
curl -s -X POST "$DENKO?source=agent&agent=Antigravity&event=waiting&project=$PWD"
```

| パラメータ | 意味 |
|---|---|
| `agent` | 表示する名前（`Gemini` を含む名前は GEMINI の見出しで流れます） |
| `event` | `waiting`（許可待ち・入力待ち）または `done`（作業完了） |
| `title` | 文を自分で決めたいとき |
| `project` | 作業フォルダ。最後のフォルダ名が（　）で付きます |

フックの機能がないツールでも、長いコマンドの後ろに付ければ完了の合図になります。

```bash
npm test; curl -s -X POST "$DENKO?source=agent&agent=テスト&event=done"
```

## レシピ

### 長いコマンドが終わったら知らせる

`~/.zshrc` に追加します。

```bash
denko() { curl -s -X POST "$DENKO" --data-urlencode "title=$*" >/dev/null; }
# 使い方: make release; denko "リリースビルド完了"
```

### ショートカット App から

1. 「URL の内容を取得」アクションを追加
2. URL に `$DENKO?title=…` を入れ、方法を **POST** にする

### 定期的に（cron / launchd）

```bash
# 平日の朝 9 時にひとこと流す例（crontab -e）
0 9 * * 1-5 curl -s -X POST "http://127.0.0.1:47326/notify/<トークン>?title=今日も一日がんばろう"
```

## 困ったとき

- **何も流れない**：設定 → 連携 の「お知らせを掲示板に流す」がオンか、設定 → 掲示板 でその種類が「流さない」になっていないかを確認してください。
- **集中モード中**：初期設定では緊急のお知らせだけが流れます（設定 → 掲示板 → 集中モード）。
- **受信口の設定を見たい**：設定 → 情報連携 →「Webhook」に受信口の設定があります。
