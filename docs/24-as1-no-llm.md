# AI Server 1 serves no LLM: the relay to AI Server 2 (2026-10-12)

**The rule.** User decision, 2026-10-12: *"boot off antoines lm studio model and also migrate everything over to ai
server 2. so no llm stuff should run there unless specified."* AI Server 1 (2x RTX 3090) does **GPU training only**.
No LM Studio, llama.cpp host, Ollama, model proxy or Flash-Next bench runs on it unless the user explicitly asks.
All LLM serving is **Flash-Next on AI Server 2** (gufo, 262,144-token context, on demand through LLM mode,
[docs/17](17-ai-server-2-llm.md)).

## What was switched off on AI Server 1

| | state now |
|---|---|
| LM Studio | quit. Run key `electron.app.LM Studio --run-as-service` removed. `http-server-config.json`: `autoStartOnLaunch false`, `justInTimeModelLoading false`, bind 127.0.0.1. `settings.json`: `enableLocalService false`, `autoLoadBundledLLM false` (written without a BOM) |
| model proxy :1235 (`model-proxy.py`) | stopped; not started by `start-services.ps1` any more; task `AI-ModelProxy-Once` disabled |
| native llama.cpp host :1236 / child host | not running; `llama-host.ps1 Start/Switch` and `llama-child-host.ps1 Start` refuse; task `AI-NativeHost` disabled |
| Flash-Next benches | tasks `AI-FlashCacheSweep`, `AI-FlashCtxCache`, `AI-FlashFinalBench`, `AI-FlashOptCache`, `AI-FlashOptSweep`, `AI-FlashVerify` disabled; jobkinds `flashbench`, `flashtune`, `flashtune2` and `tmp\flash\tune.ps1` refuse |
| `load-model.ps1`, `agentic-coding-session.ps1 Acquire` | refuse |
| idle monitor | never reloads LM Studio models (`Invoke-LmStudioRestore` is a no-op; `state\lmstudio-restore.json` removed) |
| Ollama | was not installed |

The guard is `scripts\as1-llm-policy.ps1` (`Assert-AS1LlmAllowed`), dot-sourced by each of those scripts. Refusals
are logged to `logs\as1-llm-policy.log`. **Override** (only when the user asks for an LLM on AI Server 1): create
`C:\AI-Server\state\as1-llm.allowed` with who asked and why, and delete it afterwards. Backups of every changed file:
`*.bak-20261012-nollm` beside it, plus `state\backup-20261012-as1-nollm\` (LM Studio configs, Run key, restore list,
kp-reviews config).

## The relay (`scripts\as2_llm_relay.py`, task `\AI-LLMRelay`)

AI Server 1's only LLM endpoint. It serves no model: it forwards to `http://100.65.60.112:8080` and injects AI Server
2's key on the server side (`state\as2-llm-relay\llm_api_key`, ACL poopl/SYSTEM/Administrators only), so no caller
sees it. Stdlib Python, task as poopl (S4U) at startup, restart on failure; `start-services.ps1` also starts it.

| profile | listens | for | limits |
|---|---|---|---|
| `dev` | `127.0.0.1:1234`, `100.71.113.77:1234` | Antoine: pp-antoine (its firewall allows loopback 1234) and his tailnet devices (sharee rule allows 1234). Replaces LM Studio's old :1234 | 8,192 output tokens (larger `max_tokens` lowered), 1 request at a time (others wait 120 s, then 429), 6/min, 60/h, 400/day, 3 h of model time a day, LLM mode switched on at most 4 times a day |
| `internal` | `127.0.0.1:1240` | AS1's own consumers. Not reachable from pp-antoine | 32,768 output tokens, 2 at a time, 60/min |

Both profiles: any model id is answered by `qwen3.8-flash-next-uncensored`. Endpoints `GET /health`, `/status`
(limits + today's use), `/v1/models`, `POST /v1/chat/completions`, `/v1/completions`, `/v1/responses` (+
`/v1/messages` on internal). Streaming passes through.

**Guards (they fail fast and never reach AI Server 2, so a rejected request never counts as LLM use there):**
- context: a body over ~1.7 MB (6.5 bytes per token of the 262,144 budget) is answered `400 context_length_exceeded`
  at once; gufo itself rejects the rest in ~2 s with the same code. 3 such errors in 10 min block the profile for 15 min;
- repeated prompt: the same prompt (sha256 of messages/prompt/input/system) a 4th time within 10 min gets 429
  `repeated_prompt` (a looping agent);
- rate / daily budgets as in the table (429 with `Retry-After`).

**On demand:** if the model is not up, the relay runs `llm-mode on --detach` on AI Server 2 over ssh with AI Server 1's
key (`state\ssh\ai-server-2_ed25519`; its forced command `/usr/local/bin/clashjobs-ssh` allows `clashjobs ...`,
`llm-mode status [--json]`, `llm-mode on --detach`, `llm-mode touch`, nothing else, source ClashEngineering
`ops/strixhalo/clashjobs-ssh`) and waits up to 170 s, then 503 + `Retry-After`. Asleep: it sends Wake-on-LAN, keeps
trying ssh for 25 min in the background (the box also wakes on its 20-min RTC heartbeat) and switches LLM mode on
when it answers, answering 503 meanwhile. AI Server 2's own idle watcher turns LLM mode off after 30 min without real
requests; the relay sends no keepalive. LLM mode moves/freezes AI Server 2's Clash jobs by lane policy, and
memory-fitting jobs are admitted again beside the model.

Log: `logs\as2-llm-relay.log` (metadata only: profile, client, path, status, seconds, token counts; never prompt
text). Counters: `state\as2-llm-relay\usage.json` (per box-local day). Overrides: `state\as2-llm-relay\config.json`
(same keys as `DEFAULTS` in the script). Source copies: [`scripts/as1-llm-relay/`](../scripts/as1-llm-relay/) and
`korean-Pharmacy-Workspace/ops/ai-server-scripts/llm-relay/`.

## Consumers and where they point now

| consumer | before | now |
|---|---|---|
| Antoine (pp-antoine agent / relay on 8899, tailnet devices) | LM Studio `:1234` (27B, JIT, 636k-token prompts truncated and reprocessed) | relay `dev` :1234 -> AI Server 2. Same URL for him, no key, wall unchanged |
| Discord `qwen-*` channels (mini -> `dispatch_once.py` -> `qwen-agent`) | LM Studio :1234 / model proxy :1235 | `qwen-agent\config.py`: every model -> relay :1240 (`!model 27b` / `flash-1m` alias to Flash-Next) |
| `qwenresearch` jobs | LM Studio :1234 or :1235 | relay :1240; preflight waits up to 15 min for AI Server 2 (default model Flash-Next) |
| `kp-reviews` (`review_writer: "ai_server"`, dormant: the pool writer is in use) | llama-host :1236 on the 3090s | `kp-reviews\config.json` `ai_server_url http://127.0.0.1:1240`, model Flash-Next; preflight waits for AI Server 2 |
| AI administrator (`email_intake.py`, `admin-*`) | (headless Claude; no LLM of its own) | unchanged; its `inference-status` tool reports the relay and budget; standing policy says "LLM relay on :1234" |
| dsh clients (Mac `dsh-mac-proxy.mjs`, TPC `dsh-proxy.mjs`) | AI Server 2, AI Server 1 :1235 as fallback | AI Server 2 only, every model id. A live dsh session (fresh marker) or LLM mode on: `llm-mode on --detach` and wait 3 min. Otherwise a clear 503 saying how to turn it on |
| jobqueue LLM kinds | `qwenresearch`, `kp-reviews`, `flashbench`, `flashtune*` | first two -> relay; flash* refuse |
| MCP / tools on the Mac pointing at AS1 :1234 / :1235 / :8080 | none found (only old Codex session logs) | |

Verified 2026-10-12: from inside pp-antoine as `antoine`, `127.0.0.1:1234` and `100.71.113.77:1234` answered (chat and
a streamed reply), while `127.0.0.1:1240`, `:8001` (Gmail MCP) and AI Server 2 `:8080` stayed blocked; no key in
his environment. A 2 MB prompt got `context_length_exceeded` in 0.0 s; the 4th identical prompt got 429; `qwen-agent`
answered through :1240; `llama-host.ps1 -Action Start` printed REFUSED.
