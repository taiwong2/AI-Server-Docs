---
name: ai-server-gpu
description: Reserve a GPU on Tai's AI server before running CUDA work, so concurrent jobs do not collide on one card. Use whenever a task allocates VRAM - inference, training, diffusion, upscaling - or when diagnosing why two jobs landed on the same GPU, why a card is power-capped, or why the machine will not sleep.
---

# Taking a GPU on the AI server

Two RTX 3090s, shared between agents, training runs and the job queue. **Never
pick a card yourself.**

## Why

"Pick the freest GPU" is not a scheduler. Free VRAM is a snapshot and says
nothing about what another process is about to allocate. Two jobs did this
simultaneously on 2026-08-24 and both took GPU 0: 322 W and 99% on one card
while the other idled at 28 W.

A lease is a declaration of intent, so the next process can see it.

## Use

```python
import os, sys
sys.path.insert(0, r"C:\AI-Server\scripts")
import gpulease

with gpulease.acquire(vram_mb=12000, job="my-task") as g:
    os.environ["CUDA_VISIBLE_DEVICES"] = str(g.gpu)
    import torch          # AFTER the env var
```

```bash
python C:\AI-Server\scripts\gpulease.py acquire --vram 20000 --job mytask --pid $$
python C:\AI-Server\scripts\gpulease.py list
python C:\AI-Server\scripts\gpulease.py release <lease-id>
python C:\AI-Server\scripts\gpulease.py reap
```

**Shell callers must pass `--pid`** (`$$` in bash, `$PID` in PowerShell). A CLI
`acquire` exits as soon as it prints, so without it the lease is reaped
immediately.

## Claim the peak, not the average

Claim what the job peaks at, including allocator growth. Under-claiming lets a
second job in and both then OOM — a lowered claim once left both cards with
66 MB free. DAT-2 tiled at 512 peaks around 2.4 GB and takes a 4 GB lease.

## A lease also

- **blocks sleep** — a model load is near-zero GPU utilisation for minutes and
  must not read as idle
- **stops the idle monitor** power-capping the cards or unloading models

Release it before a long non-GPU phase; re-acquire after.

## Do not

- Do not read `nvidia-smi` and choose a card.
- Do not avoid GPU 0 — **both cards are healthy**. Older notes about GPU 0
  thermal throttling are retired history.
- Do not exceed 350 W (GPU 0) / 390 W (GPU 1).

If a stale lease is blocking you: `gpulease.py list`, then `reap` — it drops
leases whose owner PID is gone or which have expired.

Full reference: `docs/03-gpu-leasing.md` in the ai-server-handbook repo.
