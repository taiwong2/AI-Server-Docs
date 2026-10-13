# 25. Keepers and the heartbeat table (outage-proof, 2026-10-13)

The user (2026-10-13): "a lot of functions stop working when you are out of usage." Goal: the fleet runs, heals and
keeps training for 24 h+ with **zero Claude usage**. Agents are for improvements, not for keeping things alive. This
page is (1) the audit of what still needs an agent and (2) the heartbeat table that shows the keepers are alive.

## Heartbeat table

Every keeper writes one record per pass: `{name, host, last_check, last_action, last_action_at, ok, period_s, note}`.

| keeper | host | runs as | heartbeat file |
|---|---|---|---|
| pf_watch | clash-sim | `attv3-pfwatch.timer` (3 min), **disabled** (pf run retired) | AS1 `C:\AI-Server\state\heartbeats\pf_watch.json` (via `/mnt/c`) |
| pf_learner_keeper | AS1 | task `\AI-PfLearnerKeeper` (SYSTEM, 2 min) | `C:\AI-Server\state\heartbeats\pf_learner_keeper.json` |
| clashsim_watch | AS1 | task `\AI-ClashSim-Watch` (S4U poopl, 5 min) | `C:\AI-Server\state\heartbeats\clashsim_watch.json` |
| model_archive | AS1 | task `\AI-ModelArchive` (2 h) | `C:\AI-Server\state\heartbeats\model_archive.json` (each status change of a pass) |
| hub_hostwatch | AS2 | user `jr-hostwatch.timer` (5 min) | `~/clash-jobs/state/heartbeats/hub_hostwatch.json` |
| llmmode | AS2 | user `llmmode-idle.service` (60 s, only while LLM mode is on) | `~/clash-jobs/state/heartbeats/llmmode.json` |
| aipower | AS2 | `ai-power.service` (root daemon) | `/run/ai-power/state.json` (its existing live state) |
| run_keeper | AS2 | user `run-keeper.timer` (3 min) | `~/clash-jobs/state/heartbeats/run_keeper.json` |
| train_backlog | AS2 | user `train-backlog.timer` (5 min) | `~/clash-jobs/state/heartbeats/train_backlog.json` |
| disk_guard | AS2 | user `disk-guard.timer` (5 min) | `~/clash-jobs/state/heartbeats/disk_guard.json` |
| disk_guard_cs | clash-sim | system `disk-guard.timer` (5 min, root) | AS1 `C:\AI-Server\state\heartbeats\disk_guard_cs.json` (via `/mnt/c`) |
| keepers | AS2 | user `keepers.timer` (3 min); also restarts a stale keeper | the table itself |

**Collector:** `ops/strixhalo/keepers.py collect` (user unit `keepers.timer`, every 3 min; installed with
`python3 ~/ClashEngineering/ops/strixhalo/keepers.py install`). AS1's part is one read-only ssh:
`ssh ai-server C:\Users\poopl\miniconda3\python.exe C:\AI-Server\scripts\keeper_beats.py` (heartbeat files, keeper
task state, clash-sim keeper timers, free GB of C:/G:/W:). Output: `~/clash-jobs/state/keepers.json` and
`~/clashlab-www/keepers.json`, shown as the **keepers** section of the site's Training page
(https://ai-server-2.tail215694.ts.net/training.html). `keepers.py show` prints it.

Status: `ok` (age <= 2 x period + 3 min, last pass ok) / `failing` (fresh, but reported a problem it could not fix) /
`stale` (the keeper itself is down) / `disabled` (timer or task disabled on purpose) / `unreachable` (AS1 did not
answer; last known record kept). model_archive is verified between passes from its task state (enabled, last result 0
or running, last run < 3 h); llmmode while LLM mode is off is "ok, nothing to watch" (`verified_by` says so).

Installed copies (source of truth ClashEngineering, copied from origin/main 53f7f98; old copies kept as
`*.bak-20261013`): `C:\AI-Server\scripts\{pf_learner_keeper,model_archive,keeper_beats}.py`, `C:\WSL\clashsim_watch.py`,
clash-sim `/opt/clash/attv3_units/pf_watch.py`. AS2 runs hub_hostwatch / llmmode / keepers from the deploy copy.

First live table (2026-10-13 00:40Z): 7/8 ok, pf_watch disabled, every last_check < 2 min.

## Run keeper (U2, 2026-10-13)

`ops/strixhalo/run_keeper.py` (CE c3bffe3), user unit `run-keeper.timer` on AS2, every 3 min (installed with
`python3 ~/ClashEngineering/ops/strixhalo/run_keeper.py install`; disable: `touch ~/.config/run-keeper.disabled`).
Registry `~/clash-jobs/state/runs.json` (state, not code): agents add runs with `run_keeper.py register ENTRY.json`
(fields in the script's docstring: run_dir, host local/clash-sim, mode, owner, hub, learner, actors, gates).

- **Stall:** no new metrics row for `stall_min` (15) -> resume from the newest checkpoint: AS2 clashjobs hub requeued
  (running) or resubmitted (dead) with `JR_RUN_DIR=<run>` in its env; or a systemd unit restarted (AS2 user unit, or a
  clash-sim system unit over `ssh ai-server wsl.exe -d clash-sim`); or a resume command. Then the actors are reattached
  (`C:\WSL\clashsim_watch.py --restart-actors INST`).
- **Never** while the hub is held:llm / frozen, or LLM mode is on and a requeued hub would be parked. It never calls
  llm-mode. Also waits: hub queued, resumed < stall_min ago, learner `status_url` not answering. 4 resumes in 6 h ->
  `failing` ("needs a human").
- **Gates:** each registered threshold submits one eval (`clashjobs submit`, or `clashsim submit` for clash-sim runs;
  `--after prev` chains them) once a settled checkpoint >= the step exists. Results `<run>/gates/<name>.json`, plus
  `<name>.submitted.json` (job id, checkpoint).
- **Dry-run by default** (entry `mode`); owner `gen2` entries are refused without an `ack` from the attacker-owner.
- State `~/clash-jobs/state/run_keeper.json`, log `~/clash-jobs/logs/run-keeper.log`, `run_keeper.py status`.

**No-agent test (2026-10-13, throwaway smoke run, `run_keeper_smoke.py` as user unit `rk-smoke-hub`, live entry):**
gate g20k submitted once at ckpt 22000 (01:20:43Z, job d7cacf746826, not resubmitted on later passes). Hub killed
(`systemctl --user kill -s KILL`) at 01:21:07Z; the keeper restarted it at 01:35:49Z (stalled 901 s) and it resumed
from checkpoint 31000: **kill -> stepping again in 883 s (14.7 min)**, no agent. Smoke unit stopped and unregistered
after the test. Registered real runs: none yet (gen2 opts in after the attacker-owner ack).

Known limits (U3: clashsim_watch now discovers the actor instances live);
AS2 clashjobs hubs cannot start while LLM mode is on and memory headroom is negative (by design, LLM takes precedence).

## Guards, self-heal and outage simulations (U3, 2026-10-13)

CE 33bab23 (`ops/strixhalo/disk_guard.py`, `keepers.py`, `ops/aiserver/jr/clashsim_watch.py`, `keeper_beats.py`).

- **Disk guards:** `disk_guard.py` every 5 min. AS2: user `disk-guard.timer` (deploy copy). clash-sim: system
  `disk-guard.timer` running `/opt/clash/attv3_units/disk_guard.py`. Thresholds: AS2 / low 100 GB, crit 30 GB; /tmp
  low 15 %. clash-sim / low 40 GB, crit 15 GB; /mnt/c (AS1 C:, where the vhdx lives) low 20 GB. While a volume is
  low it deletes only old junk named by a rule: tmp > 48 h, /var/crash, pip cache, job tmp dirs, `journalctl --vacuum`,
  `apt-get clean`. It never follows symlinks, never crosses filesystems and never touches run dirs or checkpoints. Below
  crit it reports failing ("needs a human"). Overrides: `~/clash-jobs/state/disk_guard.json` /
  `/etc/clash/disk_guard.json`. Log: `~/clash-jobs/logs/disk-guard.log` / `/var/log/clash-disk-guard.log`. AS1: G: < 30 GB
  and W: < 3 GB make clashsim_watch report failing. That is a report only; nothing is deleted on G:/W:.
- **clashsim_watch:** relay sockets and `attv3-jractors@*` units are discovered live, so the gen2 actor hosts are
  watched now. A relay restart that has no effect 3 times in a row means a 6 h backoff and failing, instead of a
  restart every 15 min.
- **Collector self-heal:** a stale keeper is restarted, at most once per 30 min. That covers enabled AS2 user timers
  (kill a hung pass, restart the timer, run one pass), `llmmode-idle` while LLM mode is on (it never turns LLM mode
  off), and AS1 keeper tasks (`schtasks /end` + `/run`). Log: `~/clash-jobs/logs/keepers-heal.log`.
- **Colab:** re-provisioning already exists, within the budget (see audit row). The remaining gap is that it depends
  on the Mac.
- **aq fallback: dsh:** not added. No routine keep-alive check is left that a keeper cannot do.

**Simulations (no agent acted; all smoke units removed afterwards):**

| failure simulated | how | healed by | t0 (UTC) | healed (UTC) | heal time |
|---|---|---|---|---|---|
| actor host kill | clash-sim smoke unit `attv3-jractors@dgsmoke` (sleep, Restart=no) `systemctl kill -s KILL` | AI-ClashSim-Watch pass: "is failed: restarted -> active" | 02:06:12 | 02:08:12 | **120 s** |
| full temp disk | clash-sim 1 GB tmpfs `/mnt/dgsim` filled to 88 % with a 900 MB file aged 3 h (override volume low 30 %) | disk_guard_cs: "removed 1 entries, freed 0.88 GB" | 02:06:11 | 02:10:47 | **276 s** |
| keeper death | AS2 `systemctl --user stop disk-guard.timer` (left enabled) | keepers collector: "disk_guard stale: restarted disk-guard" | 02:06:14 | 02:19:34 | **800 s** (stale after 2 x 5 min + 3 min) |
| hub kill (clash-sim path, first live test) | clash-sim smoke hub `rk-smoke-cs` (run_keeper_smoke.py, Restart=no) registered live, `systemctl kill -s KILL` at step 9000 | run_keeper: "stalled 903s at step 9000: restarted rk-smoke-cs", then actors reattached (`clashsim_watch --restart-actors dgsmoke`) | 02:09:01 | 02:24:09 stepping again (resumed from ckpt 7000) | **908 s** |
| hub kill (AS2 path, U2) | AS2 smoke unit `rk-smoke-hub` | run_keeper | 01:21:07 | 01:35:49 | 883 s |
| learner gone | not force-killed: the only learners are gen2's (AI-PfLearnerKeeper entries pf/8891, core/8894). Natural exit used instead: learner bc683273a0fd ended | AI-PfLearnerKeeper resubmitted 78a43974e59e | 00:23:00 | 00:24:03 | **63 s** to resubmit (the hub waits up to 900 s and re-inits) |

**What survives an outage now / what still needs an agent:**
1. Dead actor hosts on clash-sim (any `attv3-jractors@*`, gen2's too), a read-only or hung clash-sim, a missing relay: healed in <= 5-15 min.
2. A stalled registered run: resumed from its newest checkpoint in about 15 min, actors reattached, gate evals submitted once per threshold.
3. A full disk on AS2, clash-sim or AS1 C: is cleaned of junk in <= 5 min. Real data growth shows as failing on the Training page.
4. A dead keeper (timer, hung pass, llmmode-idle, AS1 task) is restarted by the collector within about 15 min. Learners are resubmitted within 2 min.
5. Still needs an agent: gen2 is not registered with run_keeper (attacker-owner ack). Gate decisions (promote / kill an arm) and new work are judgement.
6. Also still open: Colab re-provisioning needs the Mac awake (token only there), `\AI-LLMRelay` has no watchdog, and crit-level disk growth needs a human.

## Audit: what needs an agent today

| function | current keeper (deterministic) | gap (still needs an agent) | planned |
|---|---|---|---|
| training run restart / resume (gen2, jr*) | jr hubs: LLM-mode requeue reruns them with `JR_RUN_DIR` (resume from newest ckpt) after `llm-mode off`; pf: pf_watch (disabled) | registered runs: none restarted by an agent any more; unregistered runs still are | **run_keeper (U2, live)**; gen2 registers after attacker-owner ack |
| learner restarts (AS1) | AI-PfLearnerKeeper: one clashlearner per `state\pf_learners.json` entry (pf, core) | entries are hand-maintained; gen2/jr learners rely on `--learner-autostart` from the hub | U2 (registry entry carries the learner) |
| hub restarts | pf_watch (pf only, disabled); clashjobs retry | generic stall restart | U2 |
| actor restarts AS1 clash-sim | AI-ClashSim-Watch: every `attv3-jractors@*` unit clash-sim knows (discovered live since U3, so the gen2 hosts @hub / @gen2b_hub too) that is enabled but not active; distro ro/hang repair; relay. jr-hostwatch on AS2 (0 b/s -> `--restart-actors`) | none for systemd-run hosts | done (U3; sim 120 s) |
| actor restarts AS2 / Colab | AS2: clashjobs retry + LLM-mode requeue; Colab: launcher relaunch (see Colab row) | AS2 ractors jobs not in a registered run | register the run (run_keeper actors) |
| gate evals at step N | run_keeper gates (once per threshold, `<run>/gates/`) | only for unregistered runs | done (U2) |
| site / showcase refresh | clashlab-site / -monitor / -showcase / -record timers | none: active attacker runs (AS2 + clash-sim) become showcase targets automatically; stale-example alarm (`featured_stale`, > 12 h) since 2026-10-13 | done (site-auto U1-U3) |
| model archive | AI-ModelArchive (2 h) | none known | - |
| disk space | **disk_guard** (AS2 /, /tmp) + **disk_guard_cs** (clash-sim /, AS1 C: via /mnt/c) every 5 min: clean old tmp/crash/pip/journal junk while low, failing below crit; AS1 C: clashsim_watch (miniflare / wsl-crashes); AS1 G: < 30 GB / W: < 3 GB -> clashsim_watch failing (report only) | real data growth (runs, checkpoints) is never deleted: crit -> failing on the keepers page, a human decides | done (U3; fill sim 276 s) |
| relay health | clashsim_watch: relay socket names read live (attv3_hub, learner-8891, `/opt/clash/hub_relays.conf`); missing -> restart `\AI-ClashSim-Attv3Relay`; 3 restarts with no effect -> 6 h backoff + failing (the 15-min churn for the retired jr hubs stopped 02:04Z) | AS1 `\AI-LLMRelay` (as2_llm_relay, pp-antoine side) still has no watchdog (left alone: pp-antoine) | - |
| LLM mode idle off | llmmode-idle watcher; **the keepers collector restarts it when stale while LLM mode is on** (restart only, never `llm-mode off`) | none | done (U3) |
| ai-power | ai-power.service Restart=always + ai-server-2-watchdog | none | - |
| aq itself | LaunchAgent com.taiwong.agent-queue (KeepAlive, RunAtLoad); dead agents re-queued by `aq sweep` | Mac asleep / off: nothing runs. No `fallback: dsh` task added (U3): every keep-alive check is now a deterministic keeper; the remaining aq guards (gen2-guard gates / promotion, cpp-guard units) are judgement work owned by other agents and stay on Claude | - |
| Colab sessions expiring | launcher: a VM that disappears is reopened (`--max-relaunch`, state re-uploaded, budget-gated: per-job cap, `reserve_units`, `max_units_per_day` 60, `sim_max_units_per_day` 20); Mac LaunchAgent `com.clash.colab-watch` (5 min) resumes dead drivers and sweeps orphan VMs | **gap:** the drivers run on the Mac (the Colab OAuth token is only there; copying it to AS2 is the user decision), so a sleeping Mac = no re-provision; colab-watch writes no heartbeat to the keepers table | user decision on the token |
| AS1 job queue | AI-JobQueue task (Running), AI-AdminWatchdog | - | - |
