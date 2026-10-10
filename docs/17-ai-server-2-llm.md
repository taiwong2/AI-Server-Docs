# AI Server 2 (Strix Halo): the Flash-Next LLM (2026-10-10)

AI Server 2 (Minisforum MS-S1 MAX: Ryzen AI Max+ 395, Radeon 8060S `gfx1151`, 128 GB unified memory, see
[docs/15](15-ai-server-2-battle-box.md)) can serve the uncensored **Qwen3.8-Flash-Next** on **gufo**, the
Strix-Halo-only HIP engine. It is set up, verified, benchmarked, and **switched off** at the moment.

> **Status (2026-10-10): OFF.** The user's decision: the box goes full send on the battle simulator.
> `llm.target` is disabled, so nothing loads at boot. The weights stay on disk, sha256-verified.
> Bring it back: `ssh ai-server-2 sudo systemctl enable --now llm.target`. A memory gate refuses to load
> unless MemAvailable >= 104 GiB, so first stop the training/battle jobs.
> Off again: `sudo systemctl disable --now llm.target`.
> While it is off, DSH's main entry `flash-next` falls back to AI Server 1 ([docs/10](10-dsh-setup.md)).

## What runs

| | |
|---|---|
| Runtime | **gufo 0.10.0**, official image `ghcr.io/gufo-org/toolboxes/gufo-runtime:0.10.0` (pinned), rootful Podman |
| Why gufo | Its prefill is about 3x llama.cpp's on this model (published: 1,700 vs 490 tok/s pp2048), long-context decode holds up (25 tok/s AR at 128k vs 8 tok/s for llama.cpp), it runs the MTP head, and it loads in 25 s instead of 2 min. It loaded the abliterated GGUF unchanged: huihui quantized the same UD-Q4_K_XL recipe as unsloth, so the tensor types gufo requires all match. |
| Model | `huihui-ai/Huihui-Qwen3.8-Flash-Next-abliterated-GGUF`, `UD-Q4_K_XL/` (4 shards, 114.1 GB = 106.3 GiB on disk), the same weights as AI Server 1 |
| MTP draft head | `unsloth/Qwen3.8-Flash-Next-GGUF`, `MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf` (2.8 GB) |
| Model id | `qwen3.8-flash-next-uncensored` (matches AI Server 1) |
| Context | **262,144** (native, full), 1 session, **MTP on** (adaptive, up to 7 draft tokens) |
| Endpoint | `http://100.65.60.112:8080/v1` (tailnet; `ai-server-2:8080`). OpenAI Chat/Completions/Responses and Anthropic `/v1/messages`, streaming, tools. `/health`, `/ready`, `/metrics` |
| Auth | Bearer key. On the box: `/etc/ai-server-2/llm.env` (`LLM_API_KEY=`, root 600). On the Mac: `~/.config/ai-server-2/llm_api_key` (600). Every route needs it, including `/health`. |
| Thinking | On by default (Qwen `xhigh`). Per request: `"reasoning_effort": "none"` disables it |
| Vision | Not loaded (no mmproj on the box; gufo picks up `mmproj-BF16.gguf` beside the model if you add it) |
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
costs only a few GiB and needs no KV quantization. gufo's retained prompt cache is capped at 4 GiB
(`--cache-ram-bytes 4294967296`; the default would take up to 32 GiB).

**Coexistence with the battle box:** the model leaves about 23 GiB for the OS and jobs. clashjobs'
`mem_reserve_gb` was lowered to 4 to let jobs run beside it. With att-ppo-f plus v22-pool running, MemAvailable
fell to 7-11 GiB. On 2026-10-10 a second, temporary test container (loaded without the OOM guard) pushed the box
out of memory, and the kernel killed the attacker training run. Guards added since then:

- `llm-gufo` runs with `oom_score_adj -900` (Quadlet `OOMScoreAdjust` + podman `--oom-score-adj`), and `llm.slice`
  has `MemoryLow=2G`. A battle job is killed before the model.
- `ExecStartPre=/srv/llm/memcheck.sh`: no load unless MemAvailable >= 104 GiB (`Restart=always` retries every 20 s).
- `/srv/llm/testrun.sh` (temporary test servers) refuses while clashjobs has running jobs.

Rule: **no LLM load on this box while training runs.**

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
ssh ai-server-2 sudo systemctl enable --now llm.target    # on (loads in ~25 s once memory allows)
ssh ai-server-2 sudo systemctl disable --now llm.target   # off, and not at boot
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
- Vision (mmproj) not installed.
- The box is on 20 MHz Wi-Fi (~10-12 MB/s): the 114 GB download took ~5 h with two outages. Wire `enp97s0`.
