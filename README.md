# Claude Code Langfuse Hook

Claude Code の全ターンを [Langfuse](https://langfuse.com) にトレースとして送信する Stop hook。

[doneyli/claude-code-langfuse-template](https://github.com/doneyli/claude-code-langfuse-template) をベースに、以下のカスタムを追加。

## オリジナルからの変更点

- **Thinking ブロックの記録**: ネイティブ thinking ブロックと `<thinking>` タグ埋め込みの両形式に対応
- **トークン使用量の記録**: input / output / cache_creation / cache_read を Generation に付与
- **プロジェクトスコープ**: `cwd` ベースで現在のプロジェクトの transcript だけを処理（全プロジェクト走査を回避）
- **時系列ブロック記録**: thinking → text → tool_use を実行順にナンバリングした Span として記録
- **Output フィールドの修正**: thinking / text の内容を Input ではなく Output 欄に配置

## トレース構造

```
Turn N (root span)
  ├── Claude Response (generation: model, token usage)
  ├── 01 Thinking      (output: 思考内容)
  ├── 02 Text Output   (output: テキスト応答)
  ├── 03 Tool: Bash    (input: command, output: result)
  ├── 04 Thinking      (output: 思考内容)
  ├── 05 Tool: Edit    (input: file_path, output: result)
  └── 06 Text Output   (output: テキスト応答)
```

## セットアップ

### 前提

- [uv](https://docs.astral.sh/uv/) がインストール済み
- Langfuse サーバーが稼働中（セルフホスト or Cloud）

### インストール

```bash
git clone https://github.com/yutaro0915/claude-code-langfuse-hook.git
cd claude-code-langfuse-hook
./install.sh
```

### グローバル設定

`~/.claude/settings.json` に hook を登録:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "uv run --with 'langfuse>=3.0,<4.0' --python 3.12 ~/.claude/hooks/langfuse_hook.py"
          }
        ]
      }
    ]
  }
}
```

### プロジェクト単位で有効化

トレースしたいプロジェクトの `.claude/settings.local.json`:

```json
{
  "env": {
    "TRACE_TO_LANGFUSE": "true",
    "LANGFUSE_PUBLIC_KEY": "pk-lf-...",
    "LANGFUSE_SECRET_KEY": "sk-lf-...",
    "LANGFUSE_HOST": "http://localhost:3000"
  }
}
```

`TRACE_TO_LANGFUSE` が `true` でないプロジェクトでは hook は即座に終了する。

### 環境変数

| 変数 | 必須 | 説明 |
|---|---|---|
| `TRACE_TO_LANGFUSE` | Yes | `true` で有効化 |
| `LANGFUSE_PUBLIC_KEY` | Yes | Langfuse の Public Key |
| `LANGFUSE_SECRET_KEY` | Yes | Langfuse の Secret Key |
| `LANGFUSE_HOST` | No | デフォルト: `https://cloud.langfuse.com` |
| `CC_LANGFUSE_DEBUG` | No | `true` で詳細ログ出力 |

## ログ

```bash
tail -f ~/.claude/state/langfuse_hook.log
```

## Langfuse セルフホスト (Docker)

Langfuse 自体をローカルで動かす場合は [公式ドキュメント](https://langfuse.com/self-hosting/deployment/docker-compose) を参照。

## ライセンス

MIT
