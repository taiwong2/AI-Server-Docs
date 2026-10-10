# Colab: burst GPU so AI Server 1 can stay on the attacker (since 2026-10-10)

The user's decision: **AI Server 1's two RTX 3090s train the attacker learner first.** Designer GPU work
(dsg-orbit / `clashlab.designer_ar` and the grid designer `clashlab.designer`: training, fine-tunes, RWR rounds) and
small BaseFinder supervised runs run on **Google Colab** VMs instead. They are rented by the hour through the `colab`
CLI and driven by ClashEngineering's `clashlab/colab` launcher. Source of truth: ClashEngineering
`clashlab/colab/README.md`.

| | |
|---|---|
| Account | Colab Pro, compute units (balance 296 units on 2026-10-10). H100 is not entitled. A100 (40 GB SXM4), L4, T4 and G4 work. At most ~2 GPU VMs at once (a third A100 was refused). |
| CLI | `~/.local/bin/colab` on the Mac (google-colab-cli 0.7.4, OAuth token in `~/.config/colab-cli/token.json`). The token has the `cloud-platform` scope and stays on the Mac. AI Server 2 could run the driver only after the user decides to copy it. |
| Rates (measured) | A100 **5.3 units/h**, L4 **1.54 units/h**, CPU 0.08 units/h. A unit is billed per VM-hour from allocation to `colab stop`, idle or not. |
| VM | 12 vCPUs, 83 GB RAM (A100) or 53 GB (L4), python 3.13, torch 2.11 cu130, ~200 GB disk |
| Launcher | `python -m clashlab.colab ...` from a ClashEngineering checkout on the Mac |
| Jobs, ledger, cache | `~/Documents/ClashRuns/colab/{jobs,ledger.jsonl,budget.json,cache}`. Every job also gets a ClashLab run dir `~/Documents/ClashRuns/<date>-colab-<job>`. |

## Routing

| work | where |
|---|---|
| attacker learner / actors | AI Server 1, always (queue lane `attacker`, gpulease) |
| designer / designer_ar GPU training, small BaseFinder runs | Colab while the attacker holds a lease or has attacker jobs queued / running, or while AI Server 1 sleeps (never wake it for side work). AI Server 1 only when the attacker is idle and a card is free. |
| BaseFinder retrains on the 40 GB synthetic sets | AI Server 1, queued behind the attacker: 40 GB over the ~2 MB/s server uplink is 5.5 h of upload |
| CPU work | AI Server 2 clash-jobs (unchanged, [docs/15](15-ai-server-2-battle-box.md)) |

`python -m clashlab.colab route --kind designer [--data-gb N]` reads `gpulease.py list` + `jobqueue.py list` here and
answers `colab` (exit 0), `ai-server` (10) or `ai-server-wait` (11).

## Running a job

```sh
# dsg-orbit fine-tune; bare paths = data\designer_ar\... on this server (copied once to the Mac's cache, then uploaded)
# --gpu defaults to L4 for every command (run, designer-ar, grid-designer); an A100 only with --gpu A100 or an
# explicit --fallback-gpu A100, never automatically
python -m clashlab.colab designer-ar --job dsg-v22ft2 --max-units 2 \
    --init runs/v22_ft1/last.pt --extra extra_v22r2.jsonl --out v22_ft2 --push-back --detach -- --v2 ... (train.py args)
# grid designer fine-tune; bare paths = data\designer\...
python -m clashlab.colab grid-designer --job grid15-ft4 --max-units 2 --init runs/grid15_ft3/final.pt \
    --extra orbit/extra_r1.npz --out grid15_ft4 --push-back --detach -- --steps 6000 --bs 64 ... (train.py args)
python -m clashlab.colab status | logs --job X -f | stop --job X | ledger | budget
```

`--push-back` copies the finished run dir to `data\designer_ar\runs\<out>_colab` or `data\designer\runs\<out>_colab`
on this server, so the next CPU steps (sampling on AI Server 2) find it where they always do.

What the launcher guarantees:
- **Budget.** It refuses a job whose estimate exceeds `--max-units`, or that would take the balance under the 20-unit
  reserve or past 60 units a day. At the cap it pulls the state and stops the VM. Every exit path, including errors,
  SIGTERM, SIGHUP and Ctrl-C, runs `colab stop`, and a final `finally` stops a VM still live when the driver exits.
  Estimates and caps use the measured rate table (L4 1.54, A100 5.3, CPU 0.08 units/h; launcher.DEFAULT_RATES); a
  measured rate outside 0.5-2x the table is ignored.
- **No credentials or game binary on the VM.** It ships a minimal code tarball (~0.8 MB, no git clone). Datasets
  and game data exist only on the VM and die with it. `libg.so` stays home: a shim answers the id-map sha check.
- **Resume.** Resume state is pulled every 10 min. After a Colab disconnect it opens a new VM, re-uploads, and the
  trainer resumes from `last.pt`. The designer_ar time-limit exit (rc 3) reruns on the same VM.
- **Background.** `--detach` runs the driver under `caffeinate`, so the Mac stays awake.
  `ops/colab/install_watch.sh` adds a LaunchAgent: every 5 min it resumes dead drivers and runs `sweep --grace 10`:
  a finished job's VM is stopped at once, a driverless job's VM after 10 min without a poll (so ~15 min of idle
  billing at most).

## Measured (2026-10-10)

| job | AI Server 1 3090 | Colab A100 | Colab L4 |
|---|---|---|---|
| designer_ar v2.2 ft1, 8000 steps (CPU data-worker bound) | 30.8 min | 18 min, 1.85 units | 25 min, **0.67 units** |
| grid designer grid15_ft3, 6000 steps | 6.2 min | 5.7 min, 0.76 units (val_ce identical to 3 decimals) | - |

The **L4 is the launcher's default** (cheapest per job, designer jobs are data-worker bound); pass `--gpu A100` only
for GPU-bound work. Per-job overhead is 2-4 min: VM
~10 s, inputs from this server ~2 MB/s on the first use (then cached on the Mac), Mac to VM ~2-7 MB/s, VM to Mac
~6 MB/s.

## Gotchas

- Upload bodies above ~20 MB get HTTP 400 from the Colab contents API. The launcher sends 16 MB chunks.
- `colab exec` can hang on a stuck websocket. Every CLI call is killed at its timeout. Once, an exec against a
  just-released VM left a nameless VM on the account. `python -m clashlab.colab sweep --orphans --gpu X` releases
  such VMs. A browser notebook is nameless too, so always pass `--gpu`.
- Keep a vCPU free for the Jupyter kernel (designer_ar: `--workers nproc-2`). With 11 workers on 12 vCPUs a status
  poll timed out once.
