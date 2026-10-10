# AI Server 2: the Clash CPU box (battle box since 2026-10-09; all Clash CPU work since 2026-10-10)

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

## The split (since 2026-10-10): AI Server 1 trains, AI Server 2 does every Clash CPU job

The user's decision: AI Server 1 (this handbook's machine, 2x RTX 3090) does **only GPU training**. Every Clash CPU
workload moved here. Work that was already running finished where it was (BaseFinder v5 parse lanes `bf5p*`,
designer lanes `designer_gen*`, `designer_ar*`).

| workload | was | now |
|---|---|---|
| league panel / holdout battles, forge, PBS judge, `clashlab attack` / `record` | Mac (HVF) and this box | AI Server 2 (`clashjobs`; from the Mac `ops/strixhalo/onbox.sh -- CMD`) |
| designer sampling (`clashlab.designer.sample`, `clashlab.designer_ar.sample`, orbit_gen), propose, ftdata, dataset builds, realism / reports | AI Server 1 queue (lanes designer*, `basedesigner` Cmd=sample/improve) | AI Server 2 (`ops/strixhalo/jobs/designer_ar_sample.sh`, league `designer.cpu_on_box`) |
| designer / designer_ar training and fine-tunes | AI Server 1 | AI Server 1 (unchanged; from the box with `gpujob.py`, checkpoint pulled back) |
| BaseFinder parsing (`parse_scraped18`, render-and-compare) | AI Server 1 (`bf18_job.py parse`, GPU lease for the FCN) | AI Server 2 on CPU (`jobs/basefinder_parse.sh`) |
| BaseFinder synthetic rendering | AI Server 1 (`basefinder_synth` kind) | AI Server 2 (`jobs/basefinder_synth.sh`, `STREAM=1` pushes shards to AI Server 1 while rendering) |
| BaseFinder grid / level / reg18 training | AI Server 1 | AI Server 1 (unchanged) |
| scrapers (scrape2) | AI Server 1 (`run_scrape2.ps1`) | AI Server 2 (`jobs/scrape.sh`; polite 1.5 s, robots.txt, no Cloudflare evasion, never Supercell servers) |
| ClashLab site build, base-image renders (`bases render-pack`), serving :8787 | Mac + box build, AI Server 1 serves | AI Server 2 builds and serves (main copy `~/clashlab-www`); AI Server 1's :8787 redirects |
| ClashLink hub | AI Server 1 | AI Server 1 (unchanged, see below) |
| PPO learner | AI Server 1 | AI Server 1 (unchanged) |

ClashEngineering `ops/README.md` is the short version for agents (rules + commands).

### clashjobs: the CPU job runner

`ops/strixhalo/clashjobs.py` (stdlib), runner = systemd user unit `clash-jobs.service` (`Restart=always`, enabled,
starts at boot through linger; verified after the 2026-10-10 shutdown). Each job is its own transient unit
`clashjob-<id>` (systemd-run), so jobs survive runner restarts; the exit code is written by the job's wrapper.

```
ssh ai-server-2 clashjobs submit --lane L --cpus N --mem-gb G [--timeout-min M] [--after ID] [--env K=V] [--wait] -- COMMAND ...
ssh ai-server-2 clashjobs list | log ID [-f] | wait ID | cancel ID | show ID | status
C:\AI-Server\scripts\box.cmd submit ... (from AI Server 1, also from SYSTEM queue jobs)
```

- One job per lane; at most `max_running` (8) jobs; a job starts only while the running jobs' `--cpus` fit in
  `cpu_budget` = 28 of the 32 threads (the LLM keeps 2-4) and MemAvailable stays >= `--mem-gb` + 16 GB (so the LLM
  can load). `--cpus` is also a hard `CPUQuota`. Config: `~/clash-jobs/config.json`.
- Default environment: cwd `~/ClashEngineering`, its venv first on PATH, `PYTHONPATH=repo:repo/tools`.
- State and logs: `~/clash-jobs/{queue,done,failed,logs}`. Jobs killed by a shutdown show as failed with exit -15.
- AI Server 1's key (`C:\AI-Server\state\ssh\ai-server-2_ed25519`, ACL SYSTEM + Administrators only, or Windows
  OpenSSH refuses it under SYSTEM) is authorized on the box with `from="100.71.113.77"` and the forced command
  `/usr/local/bin/clashjobs-ssh`: it can run `clashjobs` and nothing else.

### Data: a mirror of AI Server 1's workspace, wsync and gpujob

`~/AlphaClash-Workspace/X` on the box = `C:\Users\poopl\Development\AlphaClash-Workspace\X` on AI Server 1 (data,
BaseFinder working copy pushed from the Mac, worktrees `bf_v5` / `ce_v5`). Launchers source
`ops/strixhalo/jobs/env.sh` (BF_ROOT, ORACLE_SIM_OUT, TORCH_HOME, REG18_DIR). Since 2026-10-10 BaseFinder is part of
ClashEngineering: env.sh sets BF_ROOT to `$CE/basefinder` once `~/ClashEngineering` has it (after the next
`tools/deploy_sync.sh --apply srv2` from the Mac), else to the old, now frozen `~/AlphaClash-Workspace/BaseFinder`.
`~/ClashEngineering` is deploy-only (it receives origin/main through deploy_sync; experiments use worktrees
`~/ce_<task>` such as ce_att / ce_dsg22); see ClashEngineering `AGENTS.md`. Mirrored so far: BaseFinder models
grid18_v5a/b, grid18_v3, level18_v2 (no last.pt / snapshots), reg18/current, oracle_sim, torch_home, gt18, scraped
sets (pull running); designer_ar dataset_ar1 + runs v2_ft2 / v21_ft1.

- `ops/strixhalo/wsync.py pull|push SRC DST`: AI Server 1 has no rsync. It compares (path, size, mtime) lists and
  moves only missing / changed files as tar-over-ssh chunks, with retries (the WAN resets connections). Nothing is
  deleted. `--settle/--watch/--until-file` stream a growing directory.
- `ops/strixhalo/gpujob.py submit --lane L --push LOCAL::REMOTE --pull REMOTE::LOCAL --wait -- "<PowerShell>"`:
  inputs up, `jobqueue.submit(kind=shell)` here, poll, checkpoint back. The command must take its own gpulease.

**Measured (2026-10-10, tailnet, two sites):** AI Server 1 -> box about **2-4.6 MB/s in total**, whatever the number
of streams or protocol (16 parallel HTTP downloads = 2.0 MB/s, 6 ssh connections = 2.2 MB/s, a later 12-stream
HTTP test 4.6 MB/s): AI Server 1's uplink is the limit. Box -> AI Server 1 about **13.5 MB/s** (1 and 6 streams the
same). So: compute on the box, push results; a 40 GB synthetic set takes about 50 min to push, and
`basefinder_synth.sh STREAM=1` overlaps it with rendering. The 24 GB dashboard copy (5.6 GB ClashLab media +
18 GB legacy recordings) takes hours in the other direction.

### ClashLab site: main copy here

- **URL: https://ai-server-2.tail215694.ts.net/** (tailnet-only HTTPS: `sudo tailscale serve --bg 8787`, persistent
  across reboots; `tailscale serve status`). Also http://ai-server-2:8787 and http://100.65.60.112:8787. Video seeking
  (HTTP Range, 206) works through serve.
- `~/clashlab-www`, served on :8787 by `clashlab-serve.service`. Built every 10 min by `clashlab-update.timer` from the runs root `~/ClashRuns`
  (holds every Mac run too, plus `clashlab_site.json` with the pins and the 18 archived runs) and published
  locally (`CLASHLAB_PUBLISH_HOST=local`: media hard-linked, text copied).
- `python -m clashlab publish` defaults to `ai-server-2:~/clashlab-www`. Runs made on the Mac:
  `ops/strixhalo/push_runs.sh`.
- AI Server 1's `AlphaClash-Dashboard` task runs `C:\AI-Server\tools\alphaclash-dash\clashlab_redirect.py`
  (switched 2026-10-10 with `set_dashboard_task.ps1` there: `Set-ScheduledTask`, because `schtasks /change` asks
  for poopl's password). HTML paths get a "moved" page with the three links and a 2 s redirect to the HTTPS URL;
  other paths a 302 to the same path there. While the legacy tree (`recordings/` 18 GB, `legacy.html`, `_logs/`) is
  still being copied it is served in place (`--keep-local`); the clashjob `legacy_redirect_done.sh` (queued
  `--after` the copy) re-runs `set_dashboard_task.ps1 -All`. Rollback: import
  `AlphaClash-Dashboard.range_server.backup.xml` (same folder); the files in `C:\AI-Server\www\alphaclash` are
  untouched.
- `clashlab update` records at most `--max-total` 12 videos per pass and only for runs with replays newer than
  `--recent-days` 2 that are not archived, and never re-records a video the site already has. Without that, the
  33 runs synced from the Mac (their media live only in the site) were being recorded again for hours, which also
  kept the box from sleeping.
- **While the box sleeps (ai-power, [docs/16](16-ai-server-2-wake-and-power.md)) the site is unreachable** until
  the 20-minute RTC heartbeat or a wake. Serving does not keep it awake by itself: `tailscaled` / `clashlab serve`
  are not busy processes, only the network gate (> 1.5 Mbit/s for a minute, i.e. someone watching videos) counts.

### ClashLink hub stays on AI Server 1

The hub submits whitelisted GPU jobs into AI Server 1's queue, serves the file roots those jobs write (designer,
league, runs, basefinder) and the PPO learner reaches it on 127.0.0.1. The box's league workers are clients. The
actor <-> learner traffic crosses the WAN once whichever side holds the hub, so moving it would add a WAN hop for
the learner and need remote job submission, for no gain. Ports: AI Server 1 8892 (hub), 8890 (learner, on demand),
8787 (redirect only); AI Server 2 8787 (ClashLab), 22, 8080 (LLM server, not Clash). No firewall on the box (ufw
inactive); Tailscale is the boundary.

### Gotchas found during the move

- **Forked workers + OpenCV deadlock.** `parse_scraped18`'s scenery pool hung forever on Linux: the parent had
  started OpenCV's thread pool, and `cv2.setNumThreads(1)` in a forked child waits on a lock that no thread will
  release (Windows spawns workers, so AI Server 1 never showed it). `basefinder_parse.sh` sets
  `OPENCV_FOR_THREADS_NUM=1`.
- **Windows OpenSSH key ACLs under SYSTEM.** A key that poopl can read is "too open" for SYSTEM. Use ACL SYSTEM +
  Administrators only (poopl is an administrator, so poopl's shells can still use it).
- **The box's Wi-Fi drops for minutes at a time** (seen twice on 2026-10-10). Running clashjobs are not affected; ssh
  sessions and transfers are, and wsync retries them. A cable is better.
- BaseFinder needs `torchvision`, `scikit-image`, `opencv-python-headless` (now in `requirements.txt` /
  `bootstrap.sh`), the reg18 model dir (`REG18_DIR`), and a ClashEngineering checkout with `artifacts/` for
  render-and-compare (the `ce_v5` worktree links the main checkout's untracked artifacts).

### Verified end to end (2026-10-10)

| check | result |
|---|---|
| designer sampling on the box (clashjob, `designer_ar_sample.sh`, dsg-orbit `v2_ft2/last.pt`, TH12-18, n=3, 24 draws, 8 CPUs) | 21 valid layouts in 5.5 min (11.3 s per draw); same seed gives the same rejections as before |
| BaseFinder parse of 20 scraped screenshots on CPU (`bf_v5` = 5af44fa, `ce_v5` = e90fa35, the server's models) vs AI Server 1's parsed18_v5 | same status 20/20, 99.87 % of objects identical (type + cell), levels equal on 99.35 % of shared objects, 4/20 layouts bit-identical (the rest differ by CPU vs CUDA float noise); 1.9 s per screenshot (server 2.3 s), 71 s wall incl. model load on 8 CPUs |
| GPU fine-tune from the box (`gpujob.py` in a clashjob -> AI Server 1 lane `designer_ar`, v2_train 300 steps) | push 45 files 15 s, queued -> running in 21 s, gpulease GPU 0 8000 MB (by `TPC2$`), 1.4 min training, checkpoint (139 MB) pulled back in 80 s; the box then sampled 4 valid TH15-16 layouts from it |
| ClashLab | box builds + publishes locally (32 runs, pins + 18 archived carried over), Mac -> box ssh publish (4,050 files, 983 MB in 11 min over the Wi-Fi LAN), HTTPS URL serves pages, media and Range (206); AI Server 1's :8787 serves the "moved" page / 302 to the same path |
| forge eval on the box (Mac `onbox.sh`, 2 box-sampled TH12 layouts, 2 seeds, 8 workers) | 32 battles in 2 s (~20/s); PBS judge (budgets 16,32) also runs |
| synthetic rendering + streaming push (`basefinder_synth.sh STREAM=1`, 1,200 images, 10 workers) | 3.4 min (5.9 images/s), 860 MB pushed to AI Server 1 complete (2,404 files); push 2.3 MB/s while the www pulls shared the Wi-Fi |
| AI Server 1 -> box submit (`box.cmd`) | works from poopl's shell and from a SYSTEM queue job; other commands are refused by the forced command |
| league `designer.cpu_on_box` (dsg1 config, tiny propose) | mirror pull + local propose run; propose then fails on the designer's known 0-valid / `np.stack([])` problem, exactly as it does on AI Server 1 |
| reboot safety | after the 2026-10-10 shutdown `clash-jobs`, `clashlab-serve`, `clashlab-update.timer` came back by themselves; jobs killed by the shutdown are recorded as failed (exit -15) and wsync jobs are simply resubmitted (resumable) |

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
| `clashlab-update.timer` | enabled, running | Every 10 min: record sampled battles, rebuild the site, publish it locally to the main copy `~/clashlab-www`. |
| `clashlab-serve.service` | enabled, running, `Restart=always` | Serves the main copy `~/clashlab-www` on `:8787` (behind `tailscale serve` HTTPS). |
| `clashlab-monitor.timer` | enabled (user, every 2 min) | `python -m clashlab.monitor collect --dest ~/clashlab-www`: writes `training.json` for the site's live **Training** page (runs + stall detection, designer/BaseFinder training dirs, AI Server 1 queue/leases/GPUs, clash-jobs, ai-power gates, LLM units, Colab, event feed). ~1.5 s CPU per pass; matches no ai-power keep-awake unit or busy process; polls AI Server 1 over ssh every pass only while it runs jobs/holds leases, else every 15 min (its jobqueue counts inbound ssh as a sleep blocker). Merges parts the Mac pushes to `~/clashlab-www/training/parts/` (Mac LaunchAgent `com.clashlab.monitor`, Colab data; pushes only when something is live, else hourly). Notes: `python -m clashlab.monitor note WORKSTREAM "text" [--next M]` (appends `~/ClashRuns/clashlab_notes.jsonl`). |
| `clash-jobs.service` | enabled, running, `Restart=always` | The CPU job runner (clashjobs). |
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
