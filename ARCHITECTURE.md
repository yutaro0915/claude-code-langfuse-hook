# Architecture: Claude Code → Langfuse Hook

このhookがClaude Codeのセッションデータをどうやって取得し、Langfuseに送っているかの詳細。

---

## 1. 全体像（30秒で把握）

```
┌─────────────────────────────────────────────────────────────────┐
│                        Claude Code (CLI)                         │
│  ユーザーの指示 → Claudeが考える → ツール使う → 応答返す          │
│                                                                  │
│  全ての会話を ~/.claude/projects/*.jsonl に追記し続ける           │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             │ 応答完了のたびに発火
                             ▼
          ┌──────────────────────────────────┐
          │   Stop hook (settings.json 設定)   │
          │                                  │
          │  uv run ~/.claude/hooks/         │
          │         langfuse_hook.py         │
          └──────────────┬───────────────────┘
                         │
                         │ stdin に session_id / cwd などのJSON
                         ▼
          ┌──────────────────────────────────┐
          │     langfuse_hook.py             │
          │                                  │
          │  1. 環境チェック (TRACE_TO_LANGFUSE)│
          │  2. 対象transcript絞り込み        │
          │  3. 差分パース                   │
          │  4. ターン毎にSpan/Generation組立 │
          │  5. Langfuseに送信               │
          └──────────────┬───────────────────┘
                         │
                         │ HTTPS (OTel Protocol)
                         ▼
          ┌──────────────────────────────────┐
          │        Langfuse Server           │
          │  localhost:3000 (self-hosted)    │
          │  Postgres + ClickHouse           │
          └──────────────────────────────────┘
```

---

## 2. いつhookが発火するか

### Claude Code の hook イベント

Claude Code が内部で発火するイベントは多数ある：

| イベント | タイミング |
|---|---|
| `SessionStart` | `claude` コマンド実行直後 |
| `UserPromptSubmit` | ユーザーが Enter を押した直後 |
| `PreToolUse` | ツール実行**前** |
| `PostToolUse` | ツール実行**後** |
| **`Stop`** | **Claudeが応答を返し終わった瞬間** ← これを使う |
| `SessionEnd` | `/exit` or Ctrl-C |

このhookは **`Stop`** だけを購読している。理由：

```
UserPromptSubmit時に送る  →  まだ応答がない、送る内容がない
PreToolUse/PostToolUse毎  →  1ターン中に何度も走る、重複になる
SessionEnd時に送る         →  長いセッションだとデータ反映が遅い
Stop時に送る              →  1ターン分が丁度揃っている ← ベスト
```

### settings.json での登録

```json
// ~/.claude/settings.json (global)
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "uv run --with 'langfuse>=3.0,<4.0' --python 3.12 ~/.claude/hooks/langfuse_hook.py"
      }]
    }]
  }
}
```

- `uv run --with 'langfuse>=3.0,<4.0'` → 依存を実行時に解決。事前の pip install 不要
- これはグローバル設定なので**全プロジェクトで発火**する（が、後述の opt-in で実質無害）

---

## 3. hookが取得する情報

### stdin で渡される JSON

Stop hook が呼ばれる時、Claude Code は stdin にこういうJSONを流す：

```json
{
  "session_id": "5dfdedba-8479-44f4-8f99-b1860a03be75",
  "cwd": "/Users/cherie/dev/langfuse",
  "hook_event_name": "Stop",
  "transcript_path": "/Users/cherie/.claude/projects/-Users-cherie-dev-langfuse/5dfdedba-...jsonl",
  "permission_mode": "default"
}
```

hookが使うのは主に:
- **`session_id`** → 1 Claude Codeセッション = 1 Langfuseセッション のキー
- **`cwd`** → プロジェクトディレクトリ判定 + settings.local.json 読み込み

### ~/.claude/projects/*.jsonl （transcript）

実際の会話データはここ。hookは `session_id` から該当ファイルを見つけて読む。

```
~/.claude/projects/
  └─ -Users-cherie-dev-langfuse/          ← cwdを "-" 置換したディレクトリ名
       ├─ 5dfdedba-....jsonl               ← セッションごとに1ファイル
       ├─ 38818776-....jsonl
       └─ subagents/                       ← サブエージェントは別ファイル（無視）
```

各行はJSON1個。形式はAnthropic APIのmessage形式に近い：

```jsonl
{"type":"user","message":{"role":"user","content":"質問内容"},"timestamp":"2026-04-17T..."}
{"type":"assistant","message":{"role":"assistant","content":[
   {"type":"thinking","thinking":"..."},
   {"type":"text","text":"..."},
   {"type":"tool_use","name":"Bash","input":{"command":"ls"},"id":"toolu_abc"}
], "usage":{"input_tokens":3,"output_tokens":470,"cache_read_input_tokens":100000}},"timestamp":"..."}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"..."}]},"toolUseResult":true,"timestamp":"..."}
```

---

## 4. 対象を絞る 3段ゲート

hookはグローバルに発火するので、無関係なデータを送らないように3重のフィルタを入れている。

```
┌──────────────────────────────────────────────────────┐
│  Stop hook 発火（全プロジェクトで）                    │
└──────────────────────┬───────────────────────────────┘
                       │
                       ▼
           ┌─────────────────────┐
    ゲート1│ TRACE_TO_LANGFUSE?  │
           └──────────┬──────────┘
                      │
            ┌─────────┴─────────┐
            ▼                   ▼
        false                  true
        即exit 0             ゲート2へ
                                │
                                ▼
           ┌──────────────────────────────┐
    ゲート2│ cwd が projects/ 配下と一致?  │
           └──────────┬───────────────────┘
                      │
                      ▼
                現プロジェクトのtranscriptだけ残す
                      │
                      ▼
           ┌──────────────────────────────┐
    ゲート3│ session_id が stdin と一致?  │
           └──────────┬───────────────────┘
                      │
                      ▼
                現セッションのtranscriptだけ残す
                      │
                      ▼
                  処理開始
```

### ゲート1: TRACE_TO_LANGFUSE env var

`.claude/settings.local.json` に書く：

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

このファイルがないプロジェクトでは hook は即座に `exit 0` する。グローバル hook が他プロジェクトに影響しない仕掛け。

**注意**: hookスクリプトは `cwd` から `settings.local.json` を**自分で読む**。Claude Code が env vars として渡すのが不安定だったため（別セッションの古い値が残るなど）。

### ゲート2: cwd フィルタ

`find_modified_transcripts()` は `~/.claude/projects/` 全部を走査するので、`cwd` で現プロジェクトに絞る：

```python
project_dir_name = cwd.replace("/", "-")
# e.g., "/Users/cherie/dev/langfuse" → "-Users-cherie-dev-langfuse"
modified_transcripts = [t for t in modified_transcripts if project_dir_name in str(t.path)]
```

### ゲート3: session_id フィルタ

同じプロジェクトでも過去セッションのtranscriptが残っているので、stdin の session_id で現セッションだけに絞る：

```python
current_session_id = hook_input.get("session_id", "")
modified_transcripts = [t for t in modified_transcripts if t.sid == current_session_id]
```

これで **1 Claude Code セッション = 1 Langfuse セッション** が保証される。

---

## 5. 差分処理（state管理）

同じセッションでも毎ターン hook は呼ばれる。毎回transcriptを全部読んで全送信していたら重複しまくる。そこで状態ファイルを使う：

```
~/.claude/state/langfuse_state.json
{
  "5dfdedba-...": {
    "last_line": 970,        ← 前回ここまで処理した
    "turn_count": 67,
    "updated": "..."
  }
}
```

処理フロー：

```
transcript を開く
  ↓
last_line から末尾まで読む（既読部分はスキップ）
  ↓
新メッセージをターン単位にグルーピング
  (user prompt → assistant群 → tool_result群) = 1ターン
  ↓
各ターンをLangfuseに送信
  ↓
state.last_line を新しい行数に更新
```

state を壊すと全件再送信になる（今日何度か踏んだ罠）。

---

## 6. ターンの内部構造（一番重要）

1ターン = 「ユーザーの指示 → Claudeの一連の応答」。これが Langfuse の1トレースになる。

### transcript上での1ターン

```
[user msg]               "claude-code langfuse hookの使い方教えて"
                          timestamp: T0
  ↓
[assistant msg 1]        thinking: "何について説明すべきか..."
                          text: "では説明します"
                          tool_use: Bash("ls")
                          timestamp: T1, usage: {in:3, out:50}
  ↓
[user msg (tool_result)] tool_use_id: toolu_abc, content: "..."
                          timestamp: T2
  ↓
[assistant msg 2]        thinking: "結果を見ると..."
                          tool_use: Read("README.md")
                          timestamp: T3, usage: {in:3, out:30}
  ↓
[user msg (tool_result)] tool_use_id: toolu_def, content: "..."
                          timestamp: T4
  ↓
[assistant msg 3]        text: "こうなっています"
                          timestamp: T5, usage: {in:3, out:200}
```

### Langfuseでの表現

```
Turn 73 (root span)
  ├── Claude Response (generation)                  ← usage合算
  │    model: claude-opus-4-6
  │    input: "使い方教えて"
  │    output: "こうなっています"
  │    usage_details: {
  │      input: 9, output: 280,
  │      cache_creation_input_tokens: ..., cache_read_input_tokens: ...
  │    }
  │
  ├── 01 Thinking                                   ← start=T1, end=T1
  │    output: "何について説明すべきか..."
  │
  ├── 02 Text Output                                ← start=T1+1µs, end=T1+1µs
  │    output: "では説明します"
  │
  ├── 03 Tool: Bash                                 ← start=T1+2µs, end=T2
  │    input: {"command": "ls"}                       ↑ 実際の所要時間
  │    output: "..."
  │
  ├── 04 Thinking                                   ← start=T3, end=T3
  │    output: "結果を見ると..."
  │
  ├── 05 Tool: Read                                 ← start=T3+1µs, end=T4
  │    input: {"file_path": "README.md"}
  │    output: "..."
  │
  └── 06 Text Output                                ← start=T5, end=T5
       output: "こうなっています"
```

---

## 7. SDK の使い分け（重要）

hookは **Langfuse高レベルSDK** と **OpenTelemetry直接** を使い分けている。

```
┌────────────────────────────────────────────────────────────────┐
│                 Langfuse Python SDK v3                          │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ 高レベルAPI                                               │  │
│  │  langfuse.start_as_current_span(name=..., input=...)    │  │
│  │  langfuse.start_as_current_observation(as_type="gen..") │  │
│  │                                                           │  │
│  │  特徴: 使いやすい、属性自動設定                            │  │
│  │  制限: start_time パラメータを受け取らない                 │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │ 内部で呼ぶ                              │
│                       ▼                                         │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ OpenTelemetry (OTel) 低レベル                            │  │
│  │  tracer.start_span(name=..., start_time=ns)             │  │
│  │  span.set_attribute("langfuse.observation.input", ...)  │  │
│  │  span.end(end_time=ns)                                  │  │
│  │                                                           │  │
│  │  特徴: タイムスタンプ完全制御可能                          │  │
│  │  制限: Langfuse固有の属性キーを自分で扱う必要あり          │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

### hookでの使い分け

| 対象 | 使うAPI | 理由 |
|---|---|---|
| Turn N (root span) | 高レベル `start_as_current_span` | タイムスタンプより属性設定の手軽さ優先 |
| Claude Response (generation) | 高レベル `start_as_current_observation` | `usage_details` パラメータが便利 |
| 01 Thinking / Text / Tool: X | **OTel直接** | 各ブロックの start/end を transcript timestamp に合わせる必要がある |

### OTel直接で使うLangfuse属性キー

```python
from langfuse._client.attributes import LangfuseOtelSpanAttributes as LA

LA.OBSERVATION_TYPE     = "langfuse.observation.type"     # "span" or "generation"
LA.OBSERVATION_INPUT    = "langfuse.observation.input"
LA.OBSERVATION_OUTPUT   = "langfuse.observation.output"
LA.OBSERVATION_METADATA = "langfuse.observation.metadata"
```

これらを `span.set_attribute()` でセットすると、Langfuseサーバー側でLangfuseの構造体に変換される。

---

## 8. タイムスタンプの話（今日の大きな修正）

### 問題

最初の実装では、全 Span が **hookが走った時刻** で作られていた：

```python
with langfuse.start_as_current_span(name="01 Thinking") as span:
    span.update(output={"thinking": ...})
# ↑ start_time = now, end_time = now + 0.1ms
```

結果、Langfuse UIで：
- 全 Span が `Latency: 0.00s` （所要時間不明）
- Spanの順序がUI表示で逆転（ほぼ同時刻のため）
- 「Bashが3秒、Readが0.1秒」のような分析が**不可能**

### 解決

transcript の timestamp を使って OTel tracer に明示的に渡す：

```python
from opentelemetry import trace as otel_trace
tracer = otel_trace.get_tracer("claude-code-langfuse-hook")

# ISOタイムスタンプをナノ秒に変換
start_ns = int(datetime.fromisoformat("2026-04-17T00:06:13Z").timestamp() * 1_000_000_000)
end_ns   = int(datetime.fromisoformat("2026-04-17T00:06:16Z").timestamp() * 1_000_000_000)

span = tracer.start_span(name="03 Tool: Bash", start_time=start_ns)
span.set_attribute(LA.OBSERVATION_TYPE, "span")
span.set_attribute(LA.OBSERVATION_INPUT, json.dumps({"command": "ls"}))
span.set_attribute(LA.OBSERVATION_OUTPUT, json.dumps("..."))
span.end(end_time=end_ns)
```

### 各ブロックの start/end マッピング

| ブロック種別 | start_time | end_time | 所要時間の意味 |
|---|---|---|---|
| thinking | assistant msgのtimestamp | 同じ | 瞬間イベント |
| text | assistant msgのtimestamp | 同じ | 瞬間イベント |
| tool_use | assistant msgのtimestamp | 対応するtool_resultのtimestamp | **ツール実行の実時間** |

### 同時刻の微小オフセット

transcript の timestamp はミリ秒精度で、同じ assistant msg 内の連続ブロックは同じタイムスタンプを持つ。そのままだとUI表示順が不定なので、`seq` 番号分のマイクロ秒を足してずらしている：

```python
if start_ns is not None:
    start_ns += seq * 1000   # 1マイクロ秒 × seq 番目
```

---

## 9. トークン使用量

Claude API は assistant message ごとに usage を返す。1ターン内に複数のAPI呼び出し（= 複数のassistant message）がある場合、全部合算：

```python
for assistant_msg in assistant_msgs:
    usage = assistant_msg.get("message", {}).get("usage", {})
    total_input_tokens       += usage.get("input_tokens", 0)
    total_output_tokens      += usage.get("output_tokens", 0)
    total_cache_creation     += usage.get("cache_creation_input_tokens", 0)
    total_cache_read         += usage.get("cache_read_input_tokens", 0)
```

この合算値を Generation オブジェクトに付与：

```python
langfuse.start_as_current_observation(
    name="Claude Response",
    as_type="generation",
    model="claude-opus-4-6",
    usage_details={
        "input": total_input_tokens,
        "output": total_output_tokens,
        "cache_creation_input_tokens": total_cache_creation,
        "cache_read_input_tokens": total_cache_read,
    },
)
```

Langfuseサーバー側でモデル名 + トークン数からコストを自動計算する。

---

## 10. 耐障害性

```
┌──────────────────────┐
│   hook実行           │
└─────────┬────────────┘
          │
          ▼
    ┌─────────────┐
    │ health check│ (socket接続でLangfuseが生きているか確認)
    └──────┬──────┘
           │
     ┌─────┴─────┐
     ▼           ▼
   生存       到達不能
     │           │
     │           ▼
     │     ┌──────────────────────────┐
     │     │ ~/.claude/state/         │
     │     │  pending_traces.jsonl    │ ← ローカルキューに溜める
     │     └──────────────────────────┘
     │           │
     │           │ 次回hook実行時にhealthyなら
     │           ▼
     │     drain_queue() で送信
     │
     ▼
  送信
```

つまり Langfuse サーバーが落ちていても Claude Code の動作には一切影響しない。再起動後にまとめて送信される。

---

## 11. 出力の最終形（UI上で見えるもの）

```
Sessions ページ:
  5dfdedba-8479-44f4-8f99-b1860a03be75
  ├── User: cherie0915y@gmail.com
  ├── Total traces: 185
  └── Total cost: $73.15

  ↓ クリック

Session詳細:
  Turn 1 → Turn 2 → Turn 3 → ... → Turn 185

  ↓ 任意のTurnをクリック

Turn 73:
  [Timeline view]
    0ms ──────────────────── 15000ms
    |[Claude Response]       |
    |[01 Thinking]           |
    |  [02 Text]             |
    |     [03 Tool: Bash]────| ← 3.2s
    |                 [04 Thinking]
    |                 [05 Tool: Read]─| ← 0.1s
    |                                 [06 Text]
```

---

## 12. 今日作ったものの全体ファイル構成

```
/Users/cherie/dev/langfuse/                          ← Langfuseサーバーのクローン
  docker-compose.yml                                  ← ClickHouseを24.12に固定（v26はaarch64でクラッシュ）
  .env                                                ← Gemini example.py 用
  example.py                                          ← SDK直接利用のサンプル
  .claude/
    settings.local.json                               ← LANGFUSE_* env vars

/Users/cherie/.claude/
  settings.json                                       ← Stop hook登録（グローバル）
  hooks/
    langfuse_hook.py                                  ← 本体（カスタム版）
  state/
    langfuse_state.json                               ← 差分処理のstate
    pending_traces.jsonl                              ← オフライン時のキュー
    langfuse_hook.log                                 ← hookログ

/Users/cherie/dev/claude-code-langfuse-hook/         ← GitHub公開リポジトリ
  langfuse_hook.py                                    ← 同じもの
  install.sh
  settings-example-*.json
  README.md
  ARCHITECTURE.md                                     ← このファイル
```
