# GPU leasing

`C:\AI-Server\scripts\gpulease.py` is the machine-wide GPU scheduler. Use it for
every job that allocates VRAM.

## Why "pick the freest GPU" is not a scheduler

On 2026-08-24 two jobs launched independently — a Real-ESRGAN benchmark and a
FLUX.1-Fill outpaint. Both queried `nvidia-smi`, both saw GPU 0 as freest at the
same instant, and both took it: **322 W and 99% on one card while the other sat
at 28 W**.

Free VRAM is a snapshot. It cannot tell you what another process is *about to*
allocate. A lease can, because it is a declaration of intent: "I am taking 20 GB
on a card for the next hour."

## Using it

```python
import os, sys
sys.path.insert(0, r"C:\AI-Server\scripts")
import gpulease

with gpulease.acquire(vram_mb=12000, job="genfill") as g:
    os.environ["CUDA_VISIBLE_DEVICES"] = str(g.gpu)
    import torch          # AFTER setting the env var
    ...
```

```bash
python C:\AI-Server\scripts\gpulease.py acquire --vram 20000 --job flux --timeout 3600 --pid $$
python C:\AI-Server\scripts\gpulease.py list
python C:\AI-Server\scripts\gpulease.py release <lease-id>
python C:\AI-Server\scripts\gpulease.py reap
```

**Shell callers must pass `--pid`.** A CLI `acquire` exits the moment it prints,
so without `--pid` the python process that created the lease is already dead and
the next reap collects it instantly. With `--pid $$` (bash) or `--pid $PID`
(PowerShell) the lease belongs to your shell.

The imaging pipeline wraps this in `common.gpu_bootstrap()`, which also preloads
torch's CUDA DLLs before onnxruntime imports — order matters there.

## How it behaves

- One JSON file per lease in `C:\AI-Server\state\gpu-leases\`.
- Every `acquire` first reaps leases whose PID is gone or whose `expires_at` has
  passed, so a crashed job cannot wedge the queue.
- A lease nobody releases dies after 6 hours.
- Ties break to the **lower** GPU index, deliberately, so nothing quietly
  recreates the old "always card 1" habit.

## Two things a lease also does

**It blocks sleep.** The queue runner treats any live lease as work in progress.
This is why a model load — near-zero GPU utilisation for several minutes — does
not read as idle.

**It tells the idle monitor to leave you alone.** No power caps, no model
unloading while a lease is live.

## Claiming the right amount

Claim what the job will *peak* at, including allocator growth, not what it uses
at steady state. Under-claiming is worse than over-claiming: it lets a second
job in and both then fail on OOM.

Measured on this box: DAT-2 super-resolution tiled at 512 peaks around 2.4 GB,
and takes a 4 GB lease. A lowered claim (11 GB → 4 GB) on a diffusion job once
left both cards over-committed with 66 MB free.

## Do not

- Do not read `nvidia-smi` and choose a card yourself.
- Do not avoid GPU 0 — both cards are healthy.
- Do not raise power limits past 350 W (GPU 0) / 390 W (GPU 1).
- Do not hold a lease across a long non-GPU phase. Release it, re-acquire.
