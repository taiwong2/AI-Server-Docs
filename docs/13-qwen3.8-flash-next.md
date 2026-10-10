# Qwen3.8-Flash-Next (uncensored) — setup, tuning, and use (added 2026-09-28)

A second large local model alongside `qwen3.8-27b-uncensored`. This one is the
`qwen4exp` architecture (the preview of Qwen4): 125B total parameters with only
~6B active per token (MoE, 512 experts / ~10 active), plus a 51B n-gram/PLE
embedding table and a built-in MTP head. It is a **thinking model with vision**.

> **Also on AI Server 2 (Strix Halo), 2026-10-10:** the same abliterated weights on the gufo engine, full 262k + MTP,
> 42.9 tok/s idle and much faster long-context prefill, no GPU lease. Currently switched off (battle box priority).
> DSH's `flash-next` entry prefers it when on. See [docs/17](17-ai-server-2-llm.md).

## What it is

| | |
|---|---|
| Model ids | `qwen3.8-flash-next-uncensored`, `qwen3.8-flash-next-uncensored-1m` |
| Weights | `huihui-ai/Huihui-Qwen3.8-Flash-Next-abliterated-GGUF` UD-Q4_K_XL, ~104 GB, at `C:\Users\poopl\.lmstudio\models\huihui-ai\...` |
| Context | 262,144 native; the `-1m` id extends to 1,048,576 via YaRN ×4 |
| Thinking | **On by default.** Disable per request with `reasoning_effort: "none"` (the :1235 proxy maps it to `chat_template_kwargs.enable_thinking=false`) |
| Vision | **Yes** — an image-text-to-text VLM. The vision projector `mmproj-model-bf16.gguf` is loaded automatically |
| Uncensored | abliterated (huihui) — refusals removed |

## Why it needs its own llama.cpp build

Mainline llama.cpp and LM Studio's bundled build cannot run this model's MTP
speculative head, and — more importantly for speed — do not have the
GPU-resident expert cache. Flash-Next runs on a **self-built binary**:

- `C:\AI-Server\tools\llama-inovello\build\bin\llama-server.exe` — the Inovello
  `flashnext-2x3090` branch (mainline + PR #27861 GPU-resident LRU expert cache
  + #28223 pinned host experts). Built with VS2022 BuildTools + CUDA 12.4,
  CUDA arch 86.
- `C:\AI-Server\tools\llama-unsloth-b11160\` is the older build (MTP but no
  expert cache); kept as a fallback only.

## Performance (measured 2026-09-28, 2× RTX 3090)

Full-quality Q4, full 262k context, single stream, MTP on:

| config | code | prose | thinking |
|---|---|---|---|
| all experts on CPU (naive) | 17 | 12 | 10 |
| static `-ot` expert split | 20 | 16 | 15 |
| **GPU-resident expert cache (deployed)** | **~36** | **~30** | **~33** tok/s |

The deployed config is ~2.1× the naive baseline. A real code generation measured
**36.4 tok/s** with 97% MTP acceptance. Bench data:
`C:\AI-Server\out\bench\flash-next.jsonl`.

### How the deployed config works

The whole model does not fit in 48 GB VRAM, so decode is bound by how fast the
CPU-resident experts stream over PCIe/RAM. The winning strategy:

- **All experts pinned in host RAM**, hot ones cached in spare VRAM:
  `-ot "ffn_(gate|up|down)_exps\.weight=CUDA_Host,per_layer_token_embd\.weight=CPU"`
  plus `--moe-expert-cache 160` (fills ~22.6/23.7 GB across both cards).
- **f16 KV** — this hybrid arch keeps a growing KV cache only on its ~12
  full-attention layers (the Gated-DeltaNet layers carry a fixed recurrent
  state), so KV is tiny and f16 costs little.
- **MTP** draft head on GPU 1: `-md <mtp-shared-Q8_0.gguf> --spec-type draft-mtp
  --spec-draft-n-max 3 -devd CUDA1`.
- `-b 4096 -ub 512`, threads 16/44, env `LLAMA_ATTN_ROT_DISABLE=1`.

Things that do **not** help (tested): `--n-cpu-moe` fills GPU 0 then GPU 1
unevenly on two cards and wastes a card (llama.cpp #15136) — do not use it;
reducing context frees little VRAM (KV is already tiny) so cache 160 is the
ceiling; `--moe-expert-cache-inserts` above the default 2 OOMs the draft load.

### Getting past ~36 tok/s

36 tok/s is the ceiling for the full 104 GB Q4 on 2× RTX 3090 — decode is
RAM-bandwidth bound. Two open levers:

1. **DDR5 speed.** RAM currently runs at **4800 MT/s** (2×48 GB). If the kit is
   EXPO-rated higher, enabling EXPO in BIOS raises memory bandwidth ~15–30% and
   therefore decode. (BIOS change; do it at the console.)
2. **A smaller model.** A REAP-pruned build (512→256 experts, ~62 GB, runs on
   the same expert-cache binary) fits far more experts resident and should clear
   ~50 tok/s, at a small quality cost and a ~62 GB download (needs disk freed).

## How to use it

**Through the model proxy (recommended)** — `http://<ai-server>:1235/v1`, same
OpenAI-compatible API and key as every other model. Request model
`qwen3.8-flash-next-uncensored`; the proxy starts or switches the native host on
demand (~90 s cold load), via the `AI-NativeHost` scheduled task.

```bash
curl http://ai-server:1235/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.8-flash-next-uncensored","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"none"}'
```

**Directly via the host script** (holds the GPUs until stopped):

```powershell
C:\AI-Server\scripts\llama-host.ps1 -Action Start -Model qwen3.8-flash-next-uncensored -Hold
# or -Model qwen3.8-flash-next-uncensored-1m for the 1M-context profile
```

**Discord** — in a `qwen-*` channel: `!model flash` (then chat), `!model 27b` to
switch back. **Research jobs** — `qwenresearch` job kind accepts
`-Model qwen3.8-flash-next-uncensored`. **DSH** — registered under the
`tai-ai-server` provider; see `10-dsh-setup.md`.

## Sampling

- Thinking: `temperature 1.0, top_p 0.95, top_k 20, min_p 0, presence_penalty 0`.
- Non-thinking: `temperature 0.7, top_p 0.8, top_k 20, presence_penalty 1.0`,
  plus `reasoning_effort: "none"`.

## Config touch points (keep these in sync)

Editing the model or its flags means editing, per integration:
`C:\AI-Server\scripts\llama-host.ps1` (models map + Launch-Native),
`C:\AI-Server\scripts\model-proxy.py` (`NATIVE_MODELS`),
`C:\AI-Server\qwen-agent\config.py` (`NATIVE_MODELS`),
`C:\AI-Server\scripts\native-host-launch.ps1` (task launcher), and each client's
DSH `cordis.patch.yml`. Server-side backups from the build-out are
`*.bak-20260927-flash`.

## Gotcha: PowerShell arg quoting

`Start-Process -ArgumentList` corrupts `-ot` values containing `| ( )`, silently
dropping the expert-placement regex. `llama-host.ps1` therefore writes the launch
command to a `.bat` and runs that for any model whose args contain those
characters, then binds to the resulting `llama-server` process.
