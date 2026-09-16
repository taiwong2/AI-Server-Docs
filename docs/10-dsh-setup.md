# DeepSeek Harness setup

This is the working native llama.cpp setup for the DeepSeek Harness (`dsh`)
from a Windows client.

## Architecture

1. `dsh-agentic.ps1` wakes the AI server, starts the native host over SSH, and
   keeps the session alive.
2. `dsh-model-proxy.mjs` listens on `127.0.0.1:1235`, exposes the installed
   model catalog, serializes model switches, and forwards OpenAI-compatible
   requests to llama.cpp.
3. `llama-host.ps1` owns both GPU leases and runs llama.cpp on port `1236`.

The proxy is the client endpoint; the native service is not exposed publicly.

## Client files

Copy these files to the same paths on the client:

```text
C:\Users\<user>\.dsh\dsh-agentic.ps1
C:\Users\<user>\.dsh\dsh-launcher.mjs
C:\Users\<user>\.dsh\dsh-model-proxy.mjs
C:\Users\<user>\.dsh\settings.yaml
```

Install Node.js 22.19 or newer, the DSH npm package, OpenSSH, and Tailscale:

```powershell
npm install -g @deepseek-ai/dsh
```

## Server requirements

Install these files on the AI server:

```text
C:\AI-Server\scripts\gpulease.py
C:\AI-Server\scripts\llama-host.ps1
```

The native host uses the bundled CUDA llama.cpp runtime and Qwen Q6 GGUF with:

```text
Qwen Q6_K, 262144 context, both RTX 3090s, layer split 1,1
Flash Attention, q8 K/V cache, batch 2048, ubatch 512
16 generation threads, 44 batch threads, parallelism 1, draft-MTP2
```

The reproducible host script is [scripts/llama-host.ps1](../scripts/llama-host.ps1).
Deploy it as `C:\AI-Server\scripts\llama-host.ps1` on another server. Keep the
model map, lease paths, and CUDA llama.cpp binary path together when cloning the
setup; edit those paths for the target account.

The measured warm benchmark was 48.32 tok/s direct and 47.19 tok/s through the
DSH proxy at 256 generated tokens. Native model switching is serialized by the
host supervisor; Authormist switched and answered in 13.77 seconds.

The handoff acquires one lease per GPU, releases both transactionally, and
resumes AlphaClash only after the native server is stopped. Dead-owner,
reused-PID, failed-load, failed-switch, idle, and crash recovery paths are
covered by the lease broker and host supervisor.

## Wake and run

The wrapper calls the tailnet-only wake relay before SSH:

```text
https://wake-relay.tail215694.ts.net/wake
```

Then run:

```powershell
dsh -l
```

Open the authenticated URL printed by DSH. A bare
`http://127.0.0.1:3080/` returns `401` by design; use the URL containing the
token.

## Verify

```powershell
tailscale ping 100.71.113.77
ssh poopl@100.71.113.77 "curl.exe -s http://127.0.0.1:1236/v1/models"
Get-Content "$env:USERPROFILE\.dsh\dsh-agentic-wrapper.log" -Tail 20
Get-Content "$env:USERPROFILE\.dsh\dsh-model-proxy.log" -Tail 20
```

Use `http://127.0.0.1:1235/v1` for client requests so model switching is
exercised. Do not expose port 1236 publicly; it has no API key in this setup.

## Subagents and multi-agent work

The installed DSH `standard` preset already enables `subagent` for one-shot or
continuable child agents, `subagent_fork` for same-route forked work,
`list_agents` and child control/messaging, plus the `workflow` engine. Workflow
helpers support fan-out with `parallel()` and ordered stages with `pipeline()`.
Child model/provider selection is enabled by the preset, so a child can use a
different model from the catalog when the task benefits from it.

This is supported, but the native host is tuned for one maximum-speed request
(`--parallel 1`). Multiple agents can overlap file and tool work; their model
turns queue behind the single llama.cpp inference slot. Do not start a separate
llama-server per child: that bypasses the shared dual-GPU lease and can cause
VRAM contention. If concurrent model turns are more important than peak
single-turn speed, benchmark a higher native `--parallel` value and its extra
KV-cache cost before changing the production profile.

For multi-GPU tuning background, see the [llama.cpp multi-GPU guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)
and [dual-3090 Qwen reports](https://www.reddit.com/r/LocalLLM/comments/1voyohk/qwen3827b_single_vs_multigpu_benchmarks/).
