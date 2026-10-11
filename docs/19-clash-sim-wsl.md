# clash-sim: attacker simulation in WSL2 on AI Server 1

Set up 2026-10-10 when the user moved attacker battles off AI Server 2 (Flash-Next needs its RAM). The 18.600 x86
engine (ClashEngineering `tools/x86_env.py`, native backend) runs in a dedicated WSL2 distro next to the 3090
learner, so rollout batches and weights no longer cross the ~1 MB/s inter-site link.

| Item | Value |
|---|---|
| Distro | `clash-sim` (Ubuntu 24.04), installed at `C:\WSL\clash-sim` (`wsl --install Ubuntu-24.04 --name clash-sim --location C:\WSL\clash-sim`) |
| Code | `/opt/clash/ce` (git clone of `AlphaClash-Workspace\ce_att`, branch `attacker`, fetched at every start) |
| Engine data | `/opt/clash/data` (artifacts subset, `extracted/lib/x86_64`, x86 snapshot, pools, army library), pushed from AI Server 2 with `wsync.py push` into `C:\WSL\stage` |
| Python | PIE CPython `/opt/clash/python3.12-pie` + `.venv` (CPU torch); engine bench digest `baca6537689509fc` verified |
| Runs as | **root** inside the distro: CAP_SYS_RAWIO maps the engine at its guest addresses, so the VM-wide `vm.mmap_min_addr` (shared with pp-antoine) is NOT changed |
| Limits | systemd scope `CPUQuota=1600%`, `MemoryMax=13G` (`ops/aiserver/clash_sim_run.sh`) |
| Run dir | `C:\WSL\runs\<run_id>` (= `/mnt/c/WSL/runs`); AI Server 2 pulls it into `~/Documents/ClashRuns` for the site (clash-job `att-run-sync`, `wsync.py pull --watch 120`) |

**Never touch pp-antoine** (Antoine's always-on distro) and **do not edit `%USERPROFILE%\.wslconfig`**: every
WSL2 distro shares one VM; a `.wslconfig` change needs `wsl --shutdown`, which would stop pp-antoine. The VM cap
stays `memory=16GB`, so clash-sim fits about 6 engines + the coordinator (~4 GB). Raising it is the user's call.

## Start / stop

| | |
|---|---|
| start | `schtasks /run /tn AI-ClashSim` (S4U task, user poopl: WSL refuses to run as SYSTEM, so job-queue jobs cannot start it) |
| stop | `type nul > C:\WSL\clash-sim.stop` (the coordinator checkpoints; the loop exits) |
| flags | `C:\WSL\clash-sim.args` (one line of `clashlab.train.run` flags incl. `--resume RUN_DIR`) |
| log | `C:\WSL\clash-sim.log` |

The task loops `ops/aiserver/clash_sim_task.ps1` -> `clash_sim_run.sh` -> `clashlab.train.supervise` (auto-resume).

## Networking (mirrored mode) and the relays

In this VM, clash-sim **cannot open TCP to Windows ports, and even Linux loopback TCP (127.0.0.1) is refused**; the
Hyper-V firewall also blocks inbound. Unix sockets work, and so does Windows interop (running `.exe` from Linux).

* learner: the coordinator uses `--learner unix:/run/clash/learner.sock`; `socat UNIX-LISTEN ... EXEC:/opt/clash/bin/winport 8890`
  runs Windows `python.exe C:\WSL\stdio_tcp.py 127.0.0.1 8890` per connection (stdio <-> TCP).
* learner autostart: `--learner-autostart local-windows` runs `jobqueue.py submit --kind clashlearner` through interop.
* actor hub (remote actor hosts, e.g. the Mac): scheduled task **AI-ClashSim-Relay** runs `C:\WSL\tcp_to_wsl.py
  0.0.0.0:8893 /run/clash/hub.sock` (per connection: `wsl.exe -d clash-sim -u root -- socat STDIO UNIX-CONNECT:...`).
  Firewall rule **clash-sim-actor-hub**: TCP 8893 inbound from the tailnet (100.64.0.0/10) only.
* outbound to the AI Server 2 hub (CA-4 attacker, attv3; 2026-10-10): clash-sim cannot reach the tailnet
  (100.65.60.112 / 192.168.10.9 both refused) but Windows can. Scheduled task **AI-ClashSim-Attv3Relay** (S4U,
  poopl, at startup, restart on failure; `C:\WSL\attv3_relay_task.ps1`) holds a `wsl.exe` session running
  `/opt/clash/bin/attv3_hubrelay.sh`: `socat UNIX-LISTEN:/run/clash/attv3_hub.sock,fork EXEC:/opt/clash/bin/attv3_hubport`
  (= Windows `python.exe C:\WSL\stdio_tcp.py 100.65.60.112 8895`). WSL interop only works inside a live
  `wsl.exe` session: a systemd unit or a SYSTEM job-queue job cannot run the relay (socat children exit with EOF /
  WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED). Remote actors connect with `--connect unix:/run/clash/attv3_hub.sock`.
  Stop: `type nul > C:\WSL\attv3-relay.stop`.
* CA-4 learner keeper: **retired 2026-10-11**. Scheduled task **AI-Attv3LearnerKeeper** is disabled (and
  `C:\WSL\attv3-learner.stop` exists): hard-wired to run e's ce_attv3 checkout, it twice put a learner with the wrong
  code on :8891 under the plan-follow run. The attacker run's own `run.py --learner-autostart ai-server --learner-ce
  <its checkout>` resubmits the `clashlearner` job (lane attv3-learner, :8891) and refuses a learner whose `/status`
  lacks the run's caps. The plan-follow run's checkout: `AlphaClash-Workspace\ce_planfollow`.
* CA-4 GPU policy in clash-sim: the job-queue job `clashpy clashlab.train.gpulease_hold` holds a gpulease and writes the
  card index to `C:\Users\poopl\attv3_lease.txt`; units set `CUDA_VISIBLE_DEVICES` from it (CUDA torch venv
  `/opt/clash/attv3_cuda`). attv3 units: real enabled systemd units installed by ClashEngineering
  `ops/aiserver/clash_sim_attv3/install_units.sh [PROCS] [ENVS]`: `attv3-infer` (shared CA-4 inference server on
  GPU0, `/run/clash/attv3_infer.sock`), `attv3-ractors` (10 actor procs x 3 envs, CPU, batched through attv3-infer)
  and `attv3-offeval` (offline checkpoint evals, GPU1 with the learner). `ATTV3_GPU` in a unit overrides the lease file.
* DNS: the generated resolv.conf points at fec0:: resolvers that do not answer; `/etc/resolv.conf` is static
  (192.168.1.1, 1.1.1.1) with `generateResolvConf = false` and systemd-resolved disabled.

## Sleep / wake

While it trains, the learner job holds a gpulease, which blocks sleep (docs/05). After `clash-sim.stop` the learner
idle-exits within 20 min and the box may sleep again; the S4U task does not wake the box by itself.

### WSL memory cap raised (2026-10-10)
`%USERPROFILE%\.wslconfig` now `memory=56GB`, `processors=24`, `swap=0` (was 16 GB, set 2026-09-01 after Docker
Desktop starved training). Raised so clash-sim can carry the attacker / CA-4 simulation and free AI Server 2 for
the LLM. Applying it needed `wsl --shutdown`, which restarts every distro (pp-antoine comes back via
`\AI-AntoineEnv`). Backup: `.wslconfig.bak-20261010`. Leaves ~37 GB + 8 threads for Windows, the GPU learners and
the job queue.

**Raised again (2026-10-10, later): `memory=64GB`, `processors=30`** (user: max capacity for simulation). Backup `.wslconfig.bak-20261010b`. Applied with `wsl --shutdown`, then `AI-AntoineEnv`, `AI-ClashSim`, `AI-ClashSim-Relay` and `AI-ClashSim-Attv3Relay` were started again. Transient systemd-run units inside clash-sim (e.g. the CA-4 remote actors) do not survive a WSL restart and must be relaunched (or made persistent units). Leaves ~29 GB + 2 threads for Windows, the GPU learners and the job queue.

### Fleet filler: fleet-teach, fleet-teach2 (2026-10-10)
Persistent units (owner: fleet-utilisation agent; consumers: the attacker / plan-exit agents) run the CA-4 PBS teacher
corpus generator in the spare CPU: `clashlab.train.teacher gen` (teach-v5 arguments, 5 envs each, cache 300 MB) ->
`/opt/clash/attv3/teacher_v5f` (seed 405) and `teacher_v5f2` (406); `fleet-teach3` (`teacher_v5f3`, 407) exists but is
disabled. Several streams because one teacher's coordinator process is single-threaded. Nice 15, CPUWeight 20,
IOWeight 20, MemoryMax 10G each, Restart=always. **Filler always yields**: keep >= 10 GB MemAvailable for owner jobs
(the dsg23 judge was OOM-killed when three 13G streams ran). **2026-10-11: fleet-teach and fleet-teach2 stopped** (memory for the pf arm's 6x6 actors, peak 42 GB); they come back only under the clash-sim runner's memory admission. Do not lower MemoryMax at runtime below current usage
(it OOM-kills the unit); shrink --envs first. Stop: `systemctl disable --now fleet-teach fleet-teach2`.

### clash-sim job runner: AS2 CPU jobs on AI Server 1 (2026-10-11)
Owner: fleet-utilisation agent. Code: ClashEngineering `ops/aiserver/clashsim.py` (AS2 driver) + `ops/strixhalo/clashjobs.py`
(the same runner as AS2, in system-unit mode).

* **Runner:** system unit `clash-jobs.service` in clash-sim (`CLASHJOBS_ROOT=/opt/clash/jobs`, `CLASHJOBS_SYSTEMD=system`);
  CLI `clashjobs` (`/usr/local/bin/clashjobs`, a wrapper). Every job is a transient `clashjob-<id>` unit with a hard
  `MemoryMax` (= `--mem-gb`, swap off), `CPUQuota` = `--cpus`, nice 5/10/19 tiers.
* **Memory admission (final, 2026-10-11 03:05 PDT):** every job unit has `OOMScoreAdjust=900` (`job_oom_score_adjust`),
  so a global OOM in the VM kills a job, never the actors / infer / offeval / pp-antoine. Guard units count at their
  current usage + 10 % while they run at >= 50 % of their remembered peak (`guard_basis: current`), and at the whole
  remembered peak (`guard_peaks.json`, survives unit restarts) while they (re)start: no job starts during an actor
  outage. Antoine reserve `mem_reserve_gb` 5. `max_load` 1.0 x 30.
* **Budget** (`/opt/clash/jobs/config.json`, read live): `total_cpu_budget` 14 of the 30 threads for all jobs together
  (the rest stays with the attacker's actors, the inference/offeval units and pp-antoine); `mem_reserve_gb` 8;
  `guard_units` attv3-ractors / attv3-infer / attv3-offeval: their unused MemoryMax is NOT handed to jobs (a
  benchmark that ignored this caused a global OOM in the VM on 2026-10-11 01:40 PDT that killed attv3-infer and
  attv3-offeval; pp-antoine was not hit). `yield_units` fleet-teach / fleet-teach2: the filler is stopped while a job
  is memory-blocked and restarted 15 min after (only units the runner itself stopped).
* **Data:** `clashsim setup --data` also mirrors AS2's `~/ClashEngineering/artifacts/` (all but `ghidra/`, which the worktrees link entry by entry) and `.toolchain/tmp/x86_oracle` (the 322 MB mode snapshot, seeded from `/opt/clash/data`, same sha256 63b0c493...). Rerun it after the engine data changes upstream.
* **Mirrored paths:** jobs see AS2's absolute paths (`/home/taiwong/...`, `HOME=/home/taiwong`). `/home/taiwong/ClashEngineering`
  holds the tracked code, `extracted/`, `.toolchain/{armies,attacker,oracle_sim}` and `.venv` -> `/opt/clash/jobs/venv`
  (AS2's exact package set, CPU torch, PIE python). Provision / refresh from AS2: `clashsim setup [--runner|--data|--venv]`.
* **Submitting (from AS2):** `clashsim submit [clashjobs flags] --cwd WORKTREE --push INPUT --pull OUTPUT -- CMD`
  queues a proxy clashjob on AS2 (`cs:NAME`, 0 CPUs, same lane / `--after`), which rsyncs the inputs over
  `ssh ai-server wsl.exe -d clash-sim -u root` (Windows interop works from an ssh session), submits, streams the log,
  pulls outputs every 10 min and at the end, and mirrors the exit code. Cancelling the proxy cancels the remote job.
  `clashsim remote list|status|log ID|cancel ID` talks to the clash-sim runner directly.
* **Stop everything:** `systemctl disable --now clash-jobs` in clash-sim (running jobs keep their own units; stop them
  with `clashjobs cancel ID`).

**2026-10-11 ~22:10 UTC: AI-ClashSim DISABLED (retired PPO actor).** `C:\WSL\clash-sim.args` still pointed it at the
retired PPO run (`--remote 100.65.60.112:8893`, learner relay 8894): a 7-proc remote actor had been looping since the
last WSL start. PPO is retired (attacker = CA-4 only), so `schtasks /change /tn AI-ClashSim /disable`, task ended,
`C:\WSL\clash-sim.stop` written, the actor and its `hub-out.sock` / `learner-8894.sock` socat relays killed. Do not
re-enable for attacker work: CA-4 actors run as `attv3-ractors`, and clash-sim batch work goes through `clashsim submit`
(clash-jobs.service). After a `wsl --shutdown`, do NOT restart AI-ClashSim.
