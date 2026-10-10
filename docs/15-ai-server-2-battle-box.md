# AI Server 2: ClashEngineering battle box (2026-10-09)

AI Server 2 is the second machine on the tailnet. It runs the CPU side of the Clash of Clans system: the exact 18.600
battle engine (x86_64 build, native runner), the league's battle workers, the ClashLink client and the ClashLab site
builder. The GPU side (designer proposals and fine-tunes, the attacker's PPO learner) stays on this handbook's AI
server and is reached through ClashLink and the job queue. The same box also runs an LLM server (podman, llama.cpp on
:8080). That server is documented separately; nothing here touches it.

| | |
|---|---|
| Hardware | Minisforum MS-S1 MAX: Ryzen AI Max+ 395 (16 Zen 5 cores / 32 threads), 128 GB unified RAM (121 GB visible to Linux) |
| OS | Ubuntu Server 26.04.1, kernel 7.0 |
| Reach it | `ssh ai-server-2` from the Mac (`HostName ai-server-2`, user `taiwong`, key `~/.ssh/ai-server-2`); tailnet `100.65.60.112`, LAN `192.168.10.9` (Wi-Fi) |
| Sudo | `taiwong` has passwordless sudo |
| Runbook (source of truth) | ClashEngineering `ops/strixhalo/README.md`: `push_from_mac.sh`, `bootstrap.sh`, `preflight.sh` |

## What is where on the box

| | |
|---|---|
| Code | `~/ClashEngineering`: a non-bare git working copy. The Mac pushes to it with `git push ai-server-2 main` (`receive.denyCurrentBranch updateInstead`). |
| Data git does not carry | `artifacts/`, `extracted/`, `.toolchain/oracle_sim/` (APK art + corpus), the x86 mode snapshot. Copied by `ops/strixhalo/push_from_mac.sh ai-server-2`, which is rsync and resumable. |
| Python | PIE CPython 3.12.15 at `~/.local/opt/python3.12-pie` (built from source; the engine needs a PIE interpreter), venv `~/ClashEngineering/.venv` with CPU torch 2.14 |
| Runs (site) | `~/ClashRuns` (`CLASHOPS_RUNS`) |
| Leagues | `~/ClashRuns/league/<name>` (`CLASHLAB_LEAGUE`); forge levels `~/ClashRuns/forge` |
| Frozen attacker for the designer league | `~/ClashRuns/attacker_frozen/att-ppo-v2-e-000000189885.pt` (Mac run `20261009-0626-att-ppo-v2-rloo-edge-th12-14-e`, latest checkpoint) |
| ClashLink | token `~/.clashlink/token`, paths `~/.clashlink/config.json` (`100.71.113.77:8892`, plus `192.168.1.24:8892`, which this box cannot reach because it is on another network) |
| ssh to this AI server | alias `ai-server`, key `~/.ssh/ai-server_strix` (authorized in poopl's `authorized_keys`, comment `strix-ai-server-2-ai-server`) |

## Services (systemd user units of taiwong, linger on, so they run at boot without a login)

| unit | state | what |
|---|---|---|
| `clashlab-update.timer` | enabled, running | Every 10 min: record sampled battles, rebuild the site, publish to `C:\AI-Server\www\alphaclash` (:8787). |
| `clashlab-serve.service` | enabled, running, `Restart=always` | Serves the box's own copy of the site on `:8787`. |
| `clashlab-league@.service` | installed, **not enabled, stopped** | `clashlab.league cycle %i --gens 1000`, `Restart=always`. |

Each unit runs `ops/strixhalo/preflight.sh --quick` as `ExecCondition`. If a dependency is missing, the run is
skipped rather than failed. The journal shows why: `journalctl --user -u <unit>`.

**Publishing from two builders.** The Mac and this box both build the site. On 2026-10-09 the box's first timer run
published its empty index (0 runs) over the dashboard's 23 runs. The Mac republished to fix it. Since ClashEngineering
`63f2b68`, a builder whose `site.json` has fewer runs than the server's keeps the server's index pages
and uploads only its additive files (per-run pages, media). `--force` overrides the guard.

## Always-on

| | |
|---|---|
| Hardware watchdog | `sp5100_tco` (`/dev/watchdog0`, "SP5100 TCO timer"). Ubuntu blacklists it and systemd-modules-load honours the blacklist, so `/etc/modules-load.d/90-watchdog.conf` alone never loaded it (fixed 2026-10-09: `ai-server-2-watchdog.service` runs `modprobe` and makes PID 1 open it). systemd (PID 1) holds the device: `RuntimeWatchdogSec=2min`, `RebootWatchdogSec=5min` (`/etc/systemd/system.conf.d/90-watchdog.conf`). Check with `cat /sys/class/watchdog/watchdog0/state` (`active`). Paused during suspend by the sleep hook. Whether a real hang actually reboots the box has **not** been tested. |
| Sleep | **Not 24/7 any more** (2026-10-09): `ai-power` suspends it when idle for 10 min and wakes it by RTC (20-min heartbeat, `clashjobs submit --at` jobs). `ai-power status` / `sudo ai-power disable`. See [AI Server 2 wake and power](16-ai-server-2-wake-and-power.md). |
| Kernel panic | `kernel.panic=10`, `kernel.panic_on_oops=1` (`/etc/sysctl.d/90-ai-server-2.conf`) |
| Updates | unattended-upgrades for security pockets only, **never reboots**: `/etc/apt/apt.conf.d/52unattended-upgrades-noreboot` |
| Power loss | Set it in the BIOS by hand: *Restore on AC power loss = Power On*. It cannot be set from Linux. |
| Engine sysctls | `vm.mmap_min_addr=4096` (`90-clash-oracle.conf`); ClashLink socket buffers (`91-clashlink.conf`) |

## Measured (native Zen 5)

Engine identity: `preflight.sh` gives bench checksum digest `baca6537689509fc`, the same battles as the Mac.
`tools/engine_regress.py check --build x86 --ticks some` over the full set: 217 battles, 40,273 steps, 67,027
full-tick checksums, 0 HARD, 0 soft.

| | AI Server 2 (native) | Mac M2 (ARM64 HVF) | x86 under Rosetta (Mac Docker) |
|---|---|---|---|
| `engine_regress --ticks none`, 4 workers, full set: CPU s/battle | **0.151** | 0.483 | 0.943 |
| `clashlab.bench`, 48 battles, 1 worker: battles/s, CPU s/battle | **6.63, 0.143** | 3.09, 0.307 | 1.27, 0.715 |
| `clashlab.bench`, 48 battles, 4 workers: battles/s | **18.8** | 5.8 | 2.8 |
| `clashlab.bench`, 1,536 battles, 16 / 24 / 32 workers: battles/s | **85.5 / 82.7 / 80.1** | | |
| RSS per engine worker | ~0.8 GB (the base cache can grow toward `cache_mb` = 2 GB on many distinct bases) | 1.24 GB | 0.81 GB |

Throughput peaks at 16 workers, one per physical core. SMT adds nothing. The CPU governor is the default
amd-pstate-epp `powersave` with EPP `balance_performance`.

**Worker sizing.**
- LLM unloaded (about 119 GB free): `workers=16`.
- LLM loaded (it can hold about 105 GB of the shared memory, which leaves about 14 GB): `workers=8`. That is
  roughly 8 x 1 GB of engine workers plus the league process, with headroom for base-cache growth.

The league's panel at 16 workers measured 21 python processes using 12.6 GB in total.

The tailnet path to this AI server is direct (not DERP), but it crosses a WAN: about 150-270 ms RTT and 1-2 MB/s
per ClashLink stream. That is fine for designer files (KB) and attacker weights (MB). It is slow for a PPO learner
streaming batches.

## The designer league (attacker training is off)

The league runs designer-only: `--preset designer` sets `attacker.train=false`, so the attacker and holdout_A
phases never run. The attacker side is frozen: A0 (random init) plus the imported checkpoint A1. Both are in the
designer's frozen evaluation panel. Designer proposals and fine-tunes run on this AI server as `basedesigner` jobs
(queue lane `league`). Panel battles run on AI Server 2.

The production league is `dsg1`. Start it with one command on AI Server 2:

```
systemctl --user enable --now clashlab-league@dsg1.service
```

Watch it with `journalctl --user -u clashlab-league@dsg1 -f`, or with
`cd ~/ClashEngineering && .venv/bin/python -m clashlab.league status dsg1`. Stop it with
`systemctl --user disable --now clashlab-league@dsg1.service`.

**Before you start `dsg1`:** the designer must produce valid layouts under its current gate. In the smoke run below,
the current designer (`runs\prior_v1n2` with working copy `e311543`, orbit-v2 hard gate) gave 0 valid layouts in
192 draws, and `improve propose` crashed on the empty result. If the league runs in that state, every generation
fails at propose and the unit restarts every 2 minutes (`Restart=always`), with each attempt taking a GPU lease for
about 25 minutes.

### Smoke run, 2026-10-09 (league `dsmoke1`, 1 generation, small sizes)

All five queue lanes were held by other jobs (bf5p0-3, designer_ar). Each league job was cancelled after 300 s and
run through `C:\AI-Server\tools\clashlink\league_direct.ps1` over ssh instead (`server.direct_after_s`, smoke
only; `dsg1` does not use it and waits for a lane).

- What worked: ClashLink connect, job submit, cancel, the direct launcher under a gpulease (the lease shows the box's
  IP `100.65.60.112`), file pull and push through the hub (`league:` root), ftdata (8 s), and the fine-tune
  D0 -> D1 (34 s).
- Gen 0 was seeded with the 7 valid candidates of `data\league\dry1\designer\gen1` (a copy, recorded in
  `data\league\dsmoke1\designer\gen0\SEEDED_FROM.txt`). With that, the full designer generation completed:
  96 panel battles on the box in 23 s, holdout_D, and the crosstable.
- AI server files: `data\league\dsmoke1\` (the smoke) and `data\league\dsg1\` (created by the first `dsg1`
  generation).
