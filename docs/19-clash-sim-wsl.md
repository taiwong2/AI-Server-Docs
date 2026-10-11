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
* CA-4 learner keeper: scheduled task **AI-Attv3LearnerKeeper** (S4U, `C:\WSL\attv3_learner_keeper.ps1`) resubmits the
  `clashlearner` job (lane attv3-learner, ce_attv3 checkout, :8891) when :8891 stops answering. Stop:
  `type nul > C:\WSL\attv3-learner.stop`.
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
