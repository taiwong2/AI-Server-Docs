# AI Server 2 (Strix Halo): the Flash-Next LLM (2026-10-10)

AI Server 2 (Minisforum MS-S1 MAX: Ryzen AI Max+ 395, Radeon 8060S `gfx1151`, 128 GB unified memory, see
[docs/15](15-ai-server-2-battle-box.md)) can serve the uncensored **Qwen3.8-Flash-Next** on **gufo**, the
Strix-Halo-only HIP engine. It is set up, verified, benchmarked, and **switched off** at the moment.

> **Status (2026-10-12): on demand through LLM mode; the default dsh backend.** Typing `dsh` on a client runs
> `llm-mode on` here: the Clash jobs move off (or are frozen or parked) by lane policy, then the model loads and is
> verified. `llm-mode off` (or the 30 min idle watcher) unloads it and gives the box back to clashjobs. `llm.target`
> stays **disabled**: it is only started, never enabled, so a reboot comes back as the CPU box. Do not use
> `systemctl enable --now llm.target` by hand. Use `llm-mode on|off|status`. See
> [LLM mode](#llm-mode-2026-10-12) below and [docs/10](10-dsh-setup.md#ai-server-2-is-the-default-backend-llm-mode).

## AI Server 1's consumers and the idle rules (2026-10-12)

AI Server 1 serves no LLM any more ([docs/24](24-as1-no-llm.md)). Its consumers (Antoine's :1234, the Discord
`qwen-*` agent, `qwenresearch`, `kp-reviews`) reach this box through AI Server 1's relay, which runs
`llm-mode on --detach` / `llm-mode status --json` here with AI Server 1's forced-command key
(`/usr/local/bin/clashjobs-ssh`: also allows `llm-mode touch`, never `off` or `move`; `LLMMODE_BY=ai-server-1-relay`).
dsh clients no longer fall back to AI Server 1 either.

Idle accounting (`llmmode.py` `last_llm_request` / `idle_s`), fixed after AS2 sat in LLM mode with idle 0.1 min and 6
frozen jobs:
- counted as use: a completed POST with status 2xx and `prompt_tokens >= 64` or `generated_tokens > 4`, or a received
  POST of >= 2 KB (a big prompt still in prefill);
- not counted: `/health`, `/v1/models`, 1-token ready/pong probes, 4xx (401, `context_length_exceeded`), and the
  cache `WARN ... tokens=` lines (before the fix every one of those counted, since the match was `POST|completion|prompt|tokens`);
- `llm-mode touch` (an open dsh window, every 5 min) counts only until `TOUCH_HOLD_MIN` (60, env
  `LLM_TOUCH_HOLD_MIN`) after the last real request or model-up. The case: a TPC dsh window (`dsh-llm-mode.ps1
  keepalive`, 100.99.161.31) held LLM mode from 03:56 UTC by touches alone. Its next request turns LLM mode on again
  through the dsh proxy.
Find what keeps the model busy: `ss -tn state established '( sport = :8080 )'` (peers) and
`journalctl -u llm-gufo | grep event=completed` (sizes).

## What runs

| | |
|---|---|
| Runtime | **gufo 0.10.0**, official image `ghcr.io/gufo-org/toolboxes/gufo-runtime:0.10.0` (pinned), rootful Podman |
| Why gufo | Its prefill is about 3x llama.cpp's on this model (published: 1,700 vs 490 tok/s pp2048), long-context decode holds up (25 tok/s AR at 128k vs 8 tok/s for llama.cpp), it runs the MTP head, and it loads in 25 s instead of 2 min. It loaded the abliterated GGUF unchanged: huihui quantized the same UD-Q4_K_XL recipe as unsloth, so the tensor types gufo requires all match. |
| Model | `huihui-ai/Huihui-Qwen3.8-Flash-Next-abliterated-GGUF`, `UD-Q4_K_XL/` (4 shards, 114.1 GB = 106.3 GiB on disk), the same weights as AI Server 1 |
| MTP draft head | `unsloth/Qwen3.8-Flash-Next-GGUF`, `MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf` (2.8 GB) |
| Model id | `qwen3.8-flash-next-uncensored` (matches AI Server 1) |
| Context | **262,144** (native, full), **2 sessions** (since 2026-10-19; was 1), **MTP on** (adaptive, up to 7 draft tokens). gufo has no RoPE/YaRN flag, so >262k is not possible on gufo |
| Endpoint | `http://100.65.60.112:8080/v1` (tailnet; `ai-server-2:8080`). OpenAI Chat/Completions/Responses and Anthropic `/v1/messages`, streaming, tools. `/health`, `/ready`, `/metrics` |
| Auth | Bearer key. On the box: `/etc/ai-server-2/llm.env` (`LLM_API_KEY=`, root 600). On the Mac: `~/.config/ai-server-2/llm_api_key` (600). Every route needs it, including `/health`. |
| Thinking | On by default (Qwen `xhigh`). Per request: `"reasoning_effort": "none"` disables it |
| Vision | **On since 2026-10-13**: `--mmproj .../UD-Q4_K_XL/mmproj-Qwen3.8-Flash-Next-BF16.gguf` (huihui-ai repo, 907,543,008 B, sha256 b1a82259...49bd0) in `/etc/containers/systemd/llm-gufo.container` (backup `/srv/llm/llm-gufo.container.bak-20261013-vision`). Tested: a red/blue PNG is described correctly. dsh clients need `defaultInput: [text, image]` on the provider (docs/10) |
| Uncensored check | Answered requests that stock models refuse (lock-picking steps, a profane roast) with no refusal; the shard hashes match huihui's abliterated files, not unsloth's |

### Memory (measured)

| config | GTT used | host MemAvailable after load |
|---|---|---|
| 262k context, MTP on (production) | **90.8 GiB** (92,979 MiB of the 120 GiB GTT cap) | 23 GiB with the box idle |
| 262k context, MTP off | 87.7 GiB | |
| 4 sessions x 32k, MTP on | 88.1 GiB | |

The 26.8 GiB per-layer-embedding (PLE / n-gram) table is IQ4_NL and only read row by row. The bytes read per
token are the experts (41 GiB Q4_K + 25 GiB Q5_1 + 4 GiB Q8_0 + 1 GiB Q5_K) times the active fraction, plus about
4 GiB of Q8_0 dense weights. The hybrid KV is small (only the full-attention layers grow), so full 262k context
costs only a few GiB and needs no KV quantization. gufo's retained prompt cache is capped at 8 GiB
(`--cache-ram-bytes 8589934592` since 2026-10-19, was 4 GiB; the default would take up to 32 GiB). With
`--sessions 2` + 8 GiB the box still shows ~13-16 GiB MemAvailable after load, as before.

**Coexistence with the battle box:** the model leaves about 23 GiB for the OS and jobs. clashjobs'
`mem_reserve_gb` was lowered to 4 to let jobs run beside it. With att-ppo-f plus v22-pool running, MemAvailable
fell to 7-11 GiB. On 2026-10-10 a second, temporary test container (loaded without the OOM guard) pushed the box
out of memory, and the kernel killed the attacker training run. Guards added since then:

- `llm-gufo` runs with `oom_score_adj -900` (Quadlet `OOMScoreAdjust` + podman `--oom-score-adj`), and `llm.slice`
  has `MemoryLow=2G`. A battle job is killed before the model.
- `ExecStartPre=/srv/llm/memcheck.sh`: no load unless MemAvailable >= 104 GiB (`Restart=always` retries every 20 s).
- `/srv/llm/testrun.sh` (temporary test servers) refuses while clashjobs has running jobs.

Rule: **no LLM load on this box while training runs**, except through `llm-mode on`, which first moves, freezes or
parks every job ([LLM mode](#llm-mode-2026-10-12)).

## LLM mode (2026-10-12)

`llm-mode` (ClashEngineering `ops/strixhalo/llmmode.py`, installed as `/usr/local/bin/llm-mode`) switches the box
between the Clash CPU box and the LLM server. The user OK'd loading the model this way on 2026-10-11, with
"any runs offloaded to Colab and other devices (not TPC)".

**on:**
1. `~/clash-jobs/llm_mode.json {"on": true}`. The clashjobs runner then starts only lanes whose policy says `new: stay`
   (drivers, report waiters, Colab drivers) and 0-CPU clashsim proxies. A submission whose lane says
   `new: clashsim`, or that passes `--portable`, is routed to AI Server 1 clash-sim (`ops/aiserver/clashsim.py`;
   same paths there, `--push` / `--pull` for inputs and outputs). It is refused with a message when it names a `~/`
   path that cannot be carried over, so nothing fails silently there. Anything else is queued as `held:llm`.
2. Every running job gets its lane's `running` action from `ops/strixhalo/llm_lanes.json`:

   | action | meaning | lanes (2026-10-12) |
   |---|---|---|
   | `stay` | keep running (tiny drivers) | attv3-pf-offsync, `*rep`, `colab*`, 0-CPU proxies |
   | `pf-hub` | attacker pf coordinator: SIGTERM (final checkpoint), run dir rsynced, resumed on clash-sim with the restart checklist (code, env, AS1 learner restart, clash-sim units) | attv3-rl |
   | `clashsim` | stop, then rerun the same command on clash-sim (it resumes from its own outputs) | planexit* (teacher gen corpus) |
   | `requeue` | stop and queue again here; reruns after off (AS2-only measurements) | engspeed*, ca4cost* |
   | `freeze` | cgroup-freeze in place (no CPU, memory kept), thawed by off. Used for jobs with no checkpoint and AS2-bound paths | dsg*, pe-sur, render*, **default for unknown lanes** |
   | `stop` | stateless helper of something that moved | attv3-ractors-as2 |
   | `requeue` (training) | the joint-restart hubs: SIGTERM (final checkpoint); rerun after off with `JR_RUN_DIR` in the job env, resuming from the newest checkpoint | attv3-jr* |
   | `requeue` / `freeze` + `short` | jr AS2 actors / jr gate evals (requeued only when the model needs the memory) | attv3-ractors-as2-jr*, jrgate* |

   A failed move falls back to `freeze` (logged with `ERROR`; retry with `llm-mode move ID`). Nothing is plainly killed.
3. `keepawake-llmmode` (user unit) keeps `ai-power` from suspending.
4. `sudo systemctl start llm.target` (memcheck: >= 104 GiB MemAvailable), then a `/health` check and a test chat
   (`reasoning_effort: none`). The 91 GiB model leaves ~24 GiB for the OS and the frozen jobs.

**LLM mode takes precedence over training (user, 2026-10-12; ClashEngineering 50ad6de).** When you want the model, it comes up:
- **Force free:** after the lane actions, if the model still cannot fit, `on` requeues, largest first, every job whose
  lane keeps its memory (`stay`, `freeze`; a frozen job holds all of it) until MemAvailable plus the freed memory reaches
  memcheck's need (104 GiB). 0-CPU proxies and jobs under 0.5 GB are left alone. A requeued job reruns its command after
  off (unknown lanes restart from their start, so long jobs should have a lane entry with a resumable action).
- **Training hubs** `attv3-jr*` are `requeue`: SIGTERM writes a final checkpoint, and after off the job reruns
  `~/jr_run.sh` with `JR_RUN_DIR` (set in the job env) and resumes from the newest checkpoint. A new joint-restart hub
  must get `JR_RUN_DIR` in its job env, or the rerun starts from `INIT`.
- **Load watchdog:** if the model is not up 180 s after `on`, the `short` lanes are freed and force-free runs again. If it
  is still not up 180 s later (it physically cannot load), LLM mode turns itself off, every job is released, and `on`
  exits 3 with the reason. `LLM_COOLDOWN_MIN` defaults to **0**, so the next `dsh` retries at once.
- **Measured (2026-10-12 23:46Z):** with both hubs, AS2 actors and 11 eval jobs running (MemAvailable 69 GiB), `llm-mode on`
  had the model answering in 64 s.
- The idle unload (30 min, 60 min with a dsh keepalive) gives the box back to training.
- Incident and recovery: [docs/08](08-troubleshooting.md#llm-mode-on-but-no-model-and-no-training-the-2026-10-12-deadlock).

**off:** stop `llm.target`, thaw frozen jobs, clear the hold (held jobs start), stop the keep-awake. Moved jobs stay
where they run.

**Idle:** `llmmode-idle` (transient user unit started by `on`) turns LLM mode off after 30 min (`LLM_IDLE_MIN`) with
no `llm-mode touch` (dsh sends one every 5 min) and no non-health request in the llm-gufo journal.

**Key:** llm-mode runs as `taiwong`, so it reads the key from `~/.config/ai-server-2/llm_api_key` (600). On first use
it copies the key there from `/etc/ai-server-2/llm.env` through `sudo -n`.

**First live run (2026-10-11 22:04 UTC):** pf was stopped cleanly at its checkpoint 5,353,149 (27 s). The AS1 learner
was restarted at the new commit (113 s), and the hub was resumed on clash-sim 292 s after the stop. planexit moved
to clash-sim. 4 jobs were frozen, 2 requeued. The model loaded and answered. Two bugs from that run are fixed: a
`~/` path parser split, and the root-only key that made every probe get 401, so the idle watcher never armed.
The pf restart on clash-sim did not stay up (the session running it died). Recovering it is owned by the attacker
workstream, not by llm-mode.

## Benchmarks (2026-10-10, 262k context, MTP on unless noted; greedy, thinking off, prose unless noted)

"Idle" is the coordinator's reference run at box load ~4. "Battle load" is load 17-34 on 32 threads
(att-ppo-f 10 CPUs + v22-pool 16 CPUs). Prompts are random-word filler with a nonce (no cache hits), and every
request generates 256 tokens. Rates are gufo's own (`usage.prompt_tokens_per_second`,
`completion_tokens_per_second`, `gufo.ttft_ms`). Script: `scripts/ais2-llm/bench_api.py CTX [MAX] [CONC] [prose|code]`.

| prompt | idle: decode | battle load: prefill | battle load: TTFT | battle load: decode (MTP) | battle load: decode (MTP off) |
|---|---|---|---|---|---|
| ~70 tokens (700 generated) | **42.9 tok/s** (prefill 308, TTFT 0.25 s, 67% draft acceptance) | | | | |
| 512 prose | | 557 | 1.0 s | 27-30 | 20.7 |
| 512 code | | 535-659 | 0.9-1.1 s | 34-41 | 23.0 |
| 8k | | 1,088 | 7.1 s | 32.8 | |
| 32k | | 1,367 | 22.5 s | 32.2 | 20.5 |
| 128k (122,496 tokens) | | 1,064 | 115 s | 27.4 | |
| 256k (233,823 tokens) | | 944 | **248 s** | 24.1 | |

Concurrency (4 sessions x 32k, 2k prompt, battle load): 1 stream 28.1 tok/s; 2 streams 21.5 + 22.8 =
**44.3 tok/s** aggregate; 4 streams 4 x 15.6 = **62.7 tok/s** aggregate, TTFT 4-11 s.

MTP draft length under battle load (`--draft-tokens` 3 / 5 / 7): prose 29.4 / 27.6 / 30.1, code
34.1 / 35.3 / 40.7 tok/s. The differences are within noise at this load, so the default (adaptive, up to 7) stays.
MTP is worth +30-60% over autoregressive decoding and costs 3.2 GiB.

**Battle contention:** decode is memory-bandwidth bound (GPU at its 2.9 GHz cap, 99% busy, ~110 W, memory
clock at its top level), and the CPU workers share the same LPDDR5X. ~26 CPUs of battle/training work cut
decode from ~43 to ~27-33 tok/s (-25 to -35%) and raise TTFT. The CPU pin (4 threads) does not help, because the
contention is memory bandwidth, not cores. Policy options: (a) the current decision, LLM off while training;
(b) throttle battle workers (clashjobs CPU budget) while the LLM is busy; (c) accept ~30 tok/s.
BIOS/platform power mode is unlikely to matter: the GPU already sits at its clock cap and the bottleneck is
memory.

**Versus published gufo numbers** (Strix Halo, same UD-Q4_K_XL + MTP): 1,700 tok/s pp2048, 25.95 tok/s AR,
31.3 tok/s MTP on mixed text, **60.4 tok/s MTP on repetitive text**. The 60 tok/s headline is the repetitive
workload, where nearly every draft is accepted. On ordinary prose, our idle 42.9 tok/s beats their 31.3 mixed
figure. The gap to 60 is acceptance (67% here on prose, higher on code). Prefill matches the published curve:
~1,400-1,600 at 8-32k when idle; ~1,100-1,370 under battle load; 944 at 234k.

**Versus AI Server 1** (2x RTX 3090, same weights, expert-cache llama.cpp, [docs/13](13-qwen3.8-flash-next.md)):
~36 tok/s code / ~30 prose / ~33 thinking. AI Server 2 idle: 42.9 prose. Under battle load: 24-33 prose,
34-41 code. AI Server 2 also prefills long contexts much faster and needs no GPU lease.

### Smaller quants?

gufo's Flash-Next loader (`src/models/qwen38_flash_next/weights.cpp`) accepts experts only in
Q4_K / Q5_K / Q6_K / Q5_1 / Q8_0, dense weights only in Q8_0 / BF16 / F16 / F32, and the PLE table only in
IQ4_NL / BF16. So the stock smaller quants (Q4_K_M, IQ4_XS, IQ3_*, Q2) do not load. The only gufo-compatible
saving is requantizing the Q5_1 / Q8_0 experts to Q4_K: about 8 GiB (~12% fewer expert bytes per token),
for maybe +8% decode. That would mean downloading huihui's abliterated Q8_0 (188 GB) and building a custom mix.
Not done.

## Halogen evaluation and the dsh slow-turn fix (2026-10-19)

**Problem:** dsh sessions at ~190k tokens took 1-6 min per turn. Cause, reproduced: with `--sessions 1` any other
client (AS1 relay, Discord bot, a dsh subagent) takes the only GPU session, and the 190k conversation's snapshot
(5-9 GB) does not fit the 4 GiB RAM cache, so the next turn re-prefills from an 88k checkpoint (64-69 s) or from 0
(~125 s). **Fix applied:** `--sessions 2 --cache-ram-bytes 8589934592` in the Quadlet (backup
`/srv/llm/llm-gufo.container.bak-20261019-sessions1`). Same trace afterwards: 1.7-2.0 s per turn.

**Halogen** ([peonist-ai/halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) 0.18.11,
image `ghcr.io/peonist-ai/halogen-flash-server@sha256:a5797467d2bff173e0c661d9700292bd55eac305faff68c86261ae35385ad6ad`)
was benchmarked side by side on the same huihui UD-Q4_K_XL GGUF (it repacks GGUFs losslessly, with its own draft
head `qwen38-flash-next-mtp.hgn`). It is a **closed-source binary** under Peonist LLC's EULA (free use, no source; the
repo has only docs, deploy scripts and bench tools; no release checksums or signatures; the image runs as root in
the container and makes no outbound connections unless `HALOGEN_DOWNLOAD` is set). **Not switched.** Files kept for a
retest: `/srv/llm/models/peonist-ai/halogen-qwen3.8-flash-next/` (MTP head, tokenizer, vision tower, sha256 = HF
LFS), `~/halogen_bench/` (results `*.jsonl`, `halogen_run.sh`), copies in `scripts/ais2-llm/`.

Script `scripts/ais2-llm/llmbench.py` (streaming, greedy, thinking off, code-file corpus with a nonce, needle at
the middle). Both engines had the box to themselves (jobs requeued), 4 CPU threads.

| | gufo 0.10.0 (old: 1 session, 4 GiB) | gufo (new: 2 sessions, 8 GiB) | halogen 0.18.11 (GGUF, 2 slots, pool 262k) |
|---|---|---|---|
| cold 32k (33k tok) TTFT | 23.6 s | | 22.2 s |
| cold 190k (186-191k) TTFT | 131 s (1,416 tok/s) | 121 s at 178k | 130 s (1,473 tok/s) |
| warm follow-up at 190k TTFT | 0.31 s | | 0.69 s |
| decode, short prose / code | 31.9 / 52.2 tok/s | | 37.6 / 58.0 tok/s |
| decode at 32k / 190k | 32.0 / 32.1 | | 38.3 / 37.8 |
| dsh trace, 178k + 2k/turn, no other client | 1 full miss in 5 (129 s; a live client hit :8080), else 1.9-2.9 s | 7/7 hits, 1.8-2.0 s | 5/5 hits, 2.5-2.8 s |
| same trace, another client between turns | **64-69 s every turn** | **1.7-2.0 s** | 2.5-2.7 s |
| 2 concurrent 32k cold / warm (wall for both) | 49.6 s (serialised) / 1.95 s | 50.7 s / 1.07 s | 44.2 s / 2.3 s; 4 pairs, no empty reply |
| largest prompt tested | 233,823 (2026-10-10) | | 242,418, needle found |
| needle at 32k / 190k; 4 short facts | ok / ok; 3/4 | | ok / ok; 3/4 (same miss) |
| memory | needs 104 GiB free; leaves 13-23 GiB | leaves 13-16 GiB | **78.2 GiB weights pinned + pool + 11 GiB work; refuses to start under ~94 GiB free + needs ~112 for the full load; leaves ~12 GiB** |

Why not switched: tuned gufo matches or beats it on the dsh case (1.7-2.0 s vs 2.5-2.7 s per turn), cold prefill
is equal, halogen's only clear win is +15-18% decode. Against that: ~8-10 GiB more RAM (every `llm-mode on` would
have to requeue almost all Clash jobs), a closed binary, open issue
[#172](https://github.com/peonist-ai/halogen-flash-server/issues/172) (K-quant GGUFs such as UD-Q4_K_XL can return
an empty reply under concurrent requests; not seen in 8 pairs here), and no vision unless its own tower is mounted.
The [Sleeping Robots A/B](https://sleepingrobots.com/dreams/halogen-vs-nathanw-qwen38-flash-next-strix-halo/)
(halogen 0.5.8 vs Nathanw llama.cpp) came to the same kind of verdict: halogen wins cold prefill, loses warm decode at
depth, closed binary, kept llama.cpp.

**1M context: not possible with this model on 128 GB.** Qwen3.8-Flash-Next is 262,144 native; the model card
allows static YaRN x4 to 1,048,576. Halogen implements it (`HALOGEN_ROPE_YARN=4 HALOGEN_CTX=1048576`; their figures:
1,004,581-token prefill 17.9 min at 937 tok/s, decode 38 tok/s, needle 9/9). Its KV costs ~28 KiB a position, so a
1M pool is ~28 GiB (+11 GiB prefill working memory at MAX_TOK 16384). With our abliterated UD-Q4_K_XL that is
78.2 + 28 + 11 + 1.3 = **~118.5 GiB of 121 GiB MemTotal**, and the engine refuses to pin below 16 GiB free: no.
524,288 (YaRN x2, 14.6 GiB pool) is ~105 GiB: only with the box empty and nothing else, so not stable either. 1M fits
only with halogen's own 62 GiB `v2` checkpoint, which is the stock (refusing) model; the only abliterated `.hgn`
(`Quat3rnion/halogen-qwen3.8-flash-next-v2-abliterated`, a re-conversion of orcarouter's BF16, 0 downloads) states
that it has no inference, quality or context validation. gufo has no RoPE scaling flag at all. Others on Strix Halo:
[strixite](https://github.com/shawnshekari/strixite) (from-scratch HIP engine, claims ~50 tok/s to 492k),
[GSQHalo.cpp](https://github.com/Aristo94/GSQHalo.cpp) (llama.cpp fork, 4 x 256k with Q8_0 KV and an SSD KV cache);
nobody reported 1M on this model on 128 GB except halogen with its own 62 GiB checkpoint. **Largest stable context
here stays 262,144.**

## Files and services (on the box)

Copies (no secrets) in this repo: `scripts/ais2-llm/`.

| | |
|---|---|
| `/etc/containers/systemd/llm-gufo.container` | Quadlet, generates `llm-gufo.service`: `Restart=always`, `RestartSec=20`, `TimeoutStopSec=90` (podman stop timeout 80 s, SIGTERM; gufo drains and exits), after `network-online`, host network, `--cpuset-cpus=14,15,30,31` (2 cores on CCD1), OOM guard, memory gate |
| `/etc/systemd/system/llm.target` | **the on/off switch** (`WantedBy=multi-user.target`). Quadlet units cannot be `systemctl enable`d directly, so `llm-gufo` is `WantedBy=` / `PartOf=llm.target` |
| `/etc/systemd/system/llm.slice` | `CPUWeight=20`, `IOWeight=20`, `MemoryLow=2G` (lower priority than the battle jobs) |
| `/etc/systemd/system/llm-model-fetch.service` + `/srv/llm/fetch-model.sh` | resumable, sha256-verified download (enabled; a no-op once verified). Writes `/srv/llm/models/.verified-qwen38-flash-next-abliterated` only when all five files match their HF LFS sha256. `llm-gufo` has `ConditionPathExists=` on that marker, so a partial file is never served (gufo also rejects a truncated shard: "Tensor extent or alignment is invalid") |
| `/srv/llm/models/` | `huihui-ai/Huihui-Qwen3.8-Flash-Next-abliterated-GGUF/UD-Q4_K_XL/*.gguf`, `unsloth/Qwen3.8-Flash-Next-GGUF/MTP/mtp-...-shared-Q8_0.gguf` |
| `/srv/llm/bench_api.py`, `/srv/llm/testrun.sh`, `/srv/llm/memcheck.sh` | benchmark, temporary test server (guarded), load gate |
| GPU access | the image runs as uid 1000 `gufo`, so the Quadlet adds the host `render` (991) and `video` (44) groups. Without them HIP reports `hipErrorNoDevice` |
| Verified in a container | `gufo diagnose`: gfx1151 available. `rocminfo` (kyuz0 image): GPU agent gfx1151, 40 CUs, pool 125,829,120 KB = **120 GiB** (kernel `amdgpu.gttsize=122880 ttm.pages_limit=31457280`, 2 GB BIOS carve-out) |
| Power | `ai-power` counts LLM connections/log lines in the last 15 min as busy, and `llm-model-fetch.service` as a keep-awake unit ([docs/16](16-ai-server-2-wake-and-power.md)) |

```bash
ssh ai-server-2 llm-mode on                               # jobs off the box, model on, verified (what dsh runs)
ssh ai-server-2 llm-mode off                              # model off, jobs back
ssh ai-server-2 llm-mode status
ssh ai-server-2 journalctl -u llm-gufo -f                 # load_completed / listening / requests
K=$(cat ~/.config/ai-server-2/llm_api_key)
curl -s http://ai-server-2:8080/v1/models -H "Authorization: Bearer $K"
```

## Switching model or runtime

- **gufo flags:** edit `Exec=` in the Quadlet, then `sudo systemctl daemon-reload && sudo systemctl restart llm-gufo`.
  `--context`, `--sessions`, `--speculative mtp|off`, `--draft-tokens`, `--cache-ram-bytes`, `--think`.
  `gufo serve llm --help` in the image lists them all.
- **gufo version:** change the image tag (`0.10.0`), `sudo podman pull` it, restart. gufo releases daily; check its
  `docs/models/qwen3.8-flash-next/` notes first.
- **Another model in gufo:** only the models gufo supports (Qwen3.8 27B, Flash-Next UD-Q4_K_XL, DeepSeek V4 Flash
  IQ2XXS, and so on), in their pinned quant layouts.
- **Fallback runtimes** (any GGUF, slower): kyuz0 `docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-10.0-strix-llama`
  (strix-llama.cpp, ~1,200 pp / ~44 tg published on Flash-Next) or `:vulkan-radv` (stock llama.cpp Vulkan;
  `-fa 1 --no-mmap -ngl 999` are mandatory on Strix Halo). Replace `Image=` and `Exec=` with
  `llama-server --host 0.0.0.0 --port 8080 -m /models/... -c 262144 -fa 1 --no-mmap -ngl 999 --api-key-file ...
  --alias qwen3.8-flash-next-uncensored`, and add `--device /dev/dri` (Vulkan needs no `/dev/kfd`).
  Neither is pulled on the box today.

## Not done / open

- **Reboot test:** skipped at the coordinator's request (it would have killed a training run). Boot autostart
  itself was seen working once: after the 2026-10-09 22:38 power cycle `llm-gufo` started by itself before
  `llm.target` existed (it then failed safely on the half-downloaded shard).
- **Idle numbers at depth** (8k-256k with the box idle) were not measured: training had priority. Expect
  prefill ~1,500-1,600 and decode ~35-43 tok/s.
- Vision: installed 2026-10-13 (see the table above). Edit the Quadlet source, not the generated unit in /run.
- The box is on 20 MHz Wi-Fi (~10-12 MB/s): the 114 GB download took ~5 h with two outages. Wire `enp97s0`.

**2026-10-12: dsh-mac-proxy also asks AS2 whether LLM mode is on.** It reads `~/clash-jobs/llm_mode.json` over ssh
(cached 60 s), in addition to the Mac marker `~/.config/ai-server-2/llm-mode.json`. While AS2 says on, flash-next goes
only to AS2, or returns 503, and never to AI Server 1's 3090s (the attacker learners). Before this, a stale marker
sent it to AS1 (model-proxy native host at 22:08 / 22:23 UTC on 2026-10-11). Backup: `bin/dsh-mac-proxy.mjs.bak-20261012`.
