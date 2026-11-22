# AI Server 1 serves no LLM: the relay to AI Server 2 (2026-10-12)

> **Override active since 2026-11-13:** the user asked for Qwen3.8 27B on AI Server 1 for dsh. It runs on both
> 3090s at `100.71.113.77:1241` (llama.cpp, task `\AI-Qwen27B`); see [the section at the end](#override-in-place-qwen38-27b-for-dsh-2026-11-13).
> Everything else below (no LM Studio, relay to AI Server 2 for the other consumers) is unchanged.

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
| `lms` CLI | `C:\Users\poopl\.lmstudio\bin\lms.exe` renamed to `lms.exe.disabled-20261012-as1-nollm`: **any** `lms` call (even `lms ps` or `lms unload`) wakes the LM Studio service. That is how LM Studio came back once during the change (an old `llama-host.ps1` cleanup ran `lms server start`); `llama-host.ps1`'s `LmStudio-Server start` is now a no-op without the override too |
| Ollama | was not installed |

The guard is `scripts\as1-llm-policy.ps1` (`Assert-AS1LlmAllowed`), dot-sourced by each of those scripts. Refusals
are logged to `logs\as1-llm-policy.log`. **Override** (only when the user asks for an LLM on AI Server 1): create
`C:\AI-Server\state\as1-llm.allowed` with who asked and why (and rename `lms.exe` back if LM Studio is wanted); undo both afterwards. Backups of every changed file:
`*.bak-20261012-nollm` beside it, plus `state\backup-20261012-as1-nollm\` (LM Studio configs, Run key, restore list,
kp-reviews config).

## The relay (`scripts\as2_llm_relay.py`, task `\AI-LLMRelay`)

AI Server 1's only LLM endpoint. It serves no model: it forwards to `http://100.65.60.112:8080` and injects AI Server
2's key on the server side (`state\as2-llm-relay\llm_api_key`, ACL poopl/SYSTEM/Administrators only), so no caller
sees it. Stdlib Python, task as poopl (S4U) at startup, restart on failure; `start-services.ps1` also starts it.

| profile | listens | for | limits |
|---|---|---|---|
| `dev` | `127.0.0.1:1234`, `100.71.113.77:1234` | Antoine: pp-antoine (its firewall allows loopback 1234) and his tailnet devices (sharee rule allows 1234). Replaces LM Studio's old :1234 | **No limits since 2026-10-13** (the user): `state\as2-llm-relay\config.json` lifts the output, rate, daily, model-time and turn-on caps and sets `repeat_guard: false`. 1 request at a time (the model serves one session; others wait up to 30 min). Only a prompt over the 262k context is rejected at once |
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

## Override in place: Qwen3.8 27B for dsh (2026-11-13)

**Why.** User, 2026-11-13 ~19:35 CST: *"can we load qwen 3.8 27b on it and then run dsh on it. that way ai server 2
is free"* (and "dont use ollama use strata"). Strata (github.com/Niko1221/Strata, v0.2.13) only runs Qwen3.8-Flash-Next,
Qwen3.6-35B-A3B and DeepSeek V4.1 (`include/strata/artifact/model_family.hpp`); it cannot load the dense 27B. The
user then chose **llama.cpp** (option C). No LM Studio, Ollama, model proxy or `llama-host.ps1` is involved; `lms.exe`
stays renamed.

| | |
|---|---|
| Override | `C:\AI-Server\state\as1-llm.allowed` ("user 2026-11-13: Qwen3.8 27B via llama.cpp ... to free AS2") |
| Weights | `C:\AI-Server\models\gguf\orcarouter\Qwen3.8-27B-Uncensored-GGUF\orcarouter_Qwen3.8-27B-Uncensored-Q4_K_M.gguf` (17.8 GB, abliterated, MTP head) + `mmproj-orcarouter_Qwen3.8-27B-Uncensored-f16.gguf` (0.93 GB, vision), from `bartowski/orcarouter_Qwen3.8-27B-Uncensored-GGUF`: the same abliterated orcarouter weights (and file names) AS1 served as `qwen3.8-27b-uncensored` before 10-12 (then Q6_K). The old files were gone; `orcarouter/...` itself is now gated on HF, bartowski's mirror is open. (A first download of `JonathanColetti/Qwen3.8-27B-Uncensored-GGUF`, a different uncensored tune, was deleted on the user's word: it must be the abliterated orcarouter model.) Q4_K_M, not Q6_K: C: had 29 GB free after purging the pip/npm/uv caches, and Q6_K + mmproj (24.4 GB) would have left < 8 GB |
| Engine | `C:\AI-Server\tools\llama-inovello\build\bin\llama-server.exe` (mainline-based build, 0.3.0-dev dd64a3d) |
| Supervisor | `C:\AI-Server\scripts\as1-qwen27b.ps1 -Action Run` (source [`scripts/as1-qwen27b/`](../scripts/as1-qwen27b/)): takes a GPU lease on each card (`qwen27b-dsh`, 21,000 MB, bound to its PID), starts llama-server, restarts it if it exits, releases the leases on exit. Exits when `state\qwen27b\stop` appears or the override file is removed |
| Task | `\AI-Qwen27B` (poopl, S4U, at startup, restart every 1 min on failure, no time limit). Download task `\AI-Qwen27B-Download` (one-shot, `scripts\qwen27b-download.ps1`, log `logs\qwen27b-download.log`) |
| Endpoint | `http://100.71.113.77:1241/v1` (tailnet only: firewall rule `AI-Qwen27B 1241 (tailnet)`, remote 100.64.0.0/10; not on the sharee list, so Antoine cannot reach it). Bearer key in `state\qwen27b\api_key` (Mac copy `~/.config/ai-server-1/qwen27b_api_key`); `/health` is open |
| Model ids | `qwen3.8-27b-uncensored`, `qwen3.8-27b-as1`, `qwen3.8-27b-strata` (all the same model) |
| Settings | ctx 262,144, `--parallel 2 --kv-unified` (two sessions share one 262k pool), KV q8_0, `--split-mode tensor --tensor-split 1,1`, flash-attn, MTP speculation (`--spec-type draft-mtp --spec-draft-n-max 2`), `--cache-ram 8192` (prompt cache in host RAM), `--jinja`, vision. VRAM: ~16.3 / 15.5 GB of 24 GB |
| Logs | `logs\qwen27b\supervisor.log`, `server.err.log` (llama.cpp log with per-request timings) |

### Benchmarks (2026-11-13 ~20:40 CST, clash-sim CPU jobs running beside it)

Measured from the Mac straight to :1241 (`max_tokens` 256, thinking off, temperature 0.6), llama.cpp timings:

| case | prompt | prefill | decode | wall | note |
|---|---:|---:|---:|---:|---|
| 1 session, cold | 20,048 tok | 1,005 tok/s | 29.6 tok/s | 30.3 s | MTP accepts ~53% of drafts |
| same 20k prefix, new question | 514 new (19,532 cached) | | 25.9 tok/s | 12.3 s | prompt cache reuse works |
| 1 session, cold | 99,952 tok | 828 tok/s | 24.8 tok/s | 133.9 s | |
| same 100k prefix, new question | 514 new (99,436 cached) | | 23.1 tok/s | 16.2 s | |
| 2 sessions at once, 20k each, cold | 2 x 20k | ~810 tok/s each | 22.1 / 9.2 tok/s* | 57.6 s total | *decode overlapped the other session's prefill |
| 2 sessions at once, short prompt | 35 tok | | 26.4 + 25.2 tok/s (~52 total) | 17.4 s | vs 29.2 tok/s for one session |

dsh end to end: `bin/dsh-check` OK in 12 s; a headless task (read a buggy file, fix it, write a pytest test, run it)
finished in 36 s with 3 tool rounds, all routed `-> as1`, and AI Server 2's LLM mode stayed off. Uncensored check: lock-picking
steps and a profane roast answered with no refusal.

### Stop / undo

```
powershell -ExecutionPolicy Bypass -File C:\AI-Server\scripts\as1-qwen27b.ps1 -Action Stop     # stops server + supervisor, releases leases
Disable-ScheduledTask AI-Qwen27B                                       # keep it off across reboots
powershell -ExecutionPolicy Bypass -File C:\AI-Server\scripts\as1-qwen27b.ps1 -Action Status   # health, pids, leases
powershell -ExecutionPolicy Bypass -File C:\AI-Server\scripts\as1-qwen27b.ps1 -Action Start    # clear the stop flag, enable + start the task
```

Note: Stop leaves `state\qwen27b\stop`, and `-Action Run` (boot trigger, restart-on-failure) exits at once while it
exists, so a stop holds until `-Action Start` (which removes it).

Full undo (back to "AS1 serves no LLM"): Stop, `Unregister-ScheduledTask AI-Qwen27B`, delete
`state\as1-llm.allowed` (the supervisor also exits by itself when that file disappears), remove the firewall rule,
optionally delete `C:\AI-Server\models\gguf\orcarouter` (18.7 GB). Then on the Mac set dsh's default back to
`flash-next` (docs/10).

**Training has priority.** The leases hold both cards (the training backlog, docs/26, only launches on AS1 cards with
< 1.5 GB used). When a GPU training run needs AI Server 1, run `-Action Stop` (dsh then answers a clear 503 for the
AS1 ids; pick `flash-next` for AI Server 2) and start the task again afterwards.

## AS1 Linux: Strata (2026-11-22)

AS1 was reinstalled with Ubuntu 26.04 on 2026-11-22; the old Windows llama.cpp endpoint (`100.71.113.77:1241`) no longer exists.
AS1 now serves one LLM again, through Strata's own engine (https://github.com/Niko1221/Strata, v0.2.19, terminal build 0.1.65).

| | |
| --- | --- |
| Endpoint | `http://100.70.25.10:8080` (tailnet only: the server binds the Tailscale address, nothing on the LAN). OpenAI `/v1/chat/completions`, Anthropic `/v1/messages`, `/v1/models`, `/health`, web UI at `/` |
| Auth | API key required (Bearer or `x-api-key`). Same key as the Mac file `~/.config/ai-server-1/qwen27b_api_key`; on AS1 it is in `~/.config/strata/env` (mode 600, `STRATA_API_KEY=`) |
| Model | OrcaRouter Qwen3.8-Flash-Next-Uncensored, IQ3_XXS (`orcarouter/Qwen3.8-Flash-Next-Uncensored-GGUF`, gated: accepted on HF account vusto; token `~/.cache/huggingface/token` on AS1). Model id: `orcarouter-qwen3.8-flash-next-uncensored-iq3_xxs` |
| Why this quant | Strata validates only IQ3_XXS for the Orca model (IQ3_M's Q5_0 expert down matrices are unsupported); expert arena 49.8 GiB RAM of 89 GB |
| Context | 262144 tokens (docs show 32K; 256K starts fine with `--kv int8`) |
| Vision | on (mmproj F16, CPU reader) |
| Drafting | MTP draft head from the original Qwen3.8-Flash-Next (`mtp_fetch/mtp_pack/mtp_rt`, q2_0 experts); acceptance not measured for this fine-tune |
| GPUs | both 3090s, layer split; 23.2 GiB used on each card; RAM about 59 GB used |
| Files | `~/orca/` : `models/` (GGUF shards, mmproj, MTP), `packs/orca-iq3_xxs` (`iq_pack.py --compat-bf16`, rounds 363 small tensors to BF16), `mtp/rt`, `strata-orca.json` (server config), `src/` (Strata v0.2.19 checkout + venv). Engine binary: released `strata` 0.1.65 CUDA 13 under `~/.local/share/strata/components` (no source build needed) |
| Service | `strata.service` (enabled, `Restart=on-failure`, 30 s). ExecStart = `ClashEngineering/ops/aiserver/as1-linux/gpurun.sh --gpu 0,1 --wait-min 0 -- ~/.local/bin/strata-service-run.sh`, so the service holds the flock leases of both cards: training jobs cannot land on them, and `systemctl stop` releases them. Cold start about 2 min (experts to RAM) |

Commands (on AS1):
`sudo systemctl stop strata` (frees both cards) / `start` / `restart`, `journalctl -u strata -f`,
`gpurun.sh --status`, monitor: `set -a; . ~/.config/strata/env; set +a; strata status --url http://100.70.25.10:8080 --credential-env STRATA_API_KEY` (views 1-6, `q` quits).

Benchmarks (Mac to AS1 over Tailscale, 2026-11-22 ~16:30 CST): 23,170-token prompt: 16.0 s to first token, about 1,440 tok/s prefill;
decode about 148 tok/s on a 400-token story (MTP on); short prompt first token 0.4 s; image (red square, blue circle) described correctly in 2.1 s;
Anthropic `/v1/messages` and key rejection (401 without key) verified. The model thinks by default (`reasoning_content`).

Notes: a `strata launch` run (family menu models) is not used; Orca is not in the menu (docs/ORCA.md). A single-stream download from Hugging Face is capped near 2 MB/s,
parallel range requests (`~/orca/models/pdl.py`) reach 50+ MB/s. The key was printed once in an agent transcript by mistake (CLI argument error); rotate it if that matters.
