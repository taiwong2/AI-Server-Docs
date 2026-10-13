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
| keepers | AS2 | user `keepers.timer` (3 min) | the table itself |

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

Known limits: clashsim_watch only knows the actor instances `jr_hub` / `jrcore_hub` (gen2 instances need adding there);
AS2 clashjobs hubs cannot start while LLM mode is on and memory headroom is negative (by design, LLM takes precedence).

## Audit: what needs an agent today

| function | current keeper (deterministic) | gap (still needs an agent) | planned |
|---|---|---|---|
| training run restart / resume (gen2, jr*) | jr hubs: LLM-mode requeue reruns them with `JR_RUN_DIR` (resume from newest ckpt) after `llm-mode off`; pf: pf_watch (disabled) | registered runs: none restarted by an agent any more; unregistered runs still are | **run_keeper (U2, live)**; gen2 registers after attacker-owner ack |
| learner restarts (AS1) | AI-PfLearnerKeeper: one clashlearner per `state\pf_learners.json` entry (pf, core) | entries are hand-maintained; gen2/jr learners rely on `--learner-autostart` from the hub | U2 (registry entry carries the learner) |
| hub restarts | pf_watch (pf only, disabled); clashjobs retry | generic stall restart | U2 |
| actor restarts AS1 clash-sim | AI-ClashSim-Watch (`attv3-jractors@jr_hub/jrcore_hub`, distro ro/hang repair, relay) + jr-hostwatch on AS2 (0 b/s -> `--restart-actors`) | gen2 actor instances not in clashsim_watch's INSTANCES; attv3-actorwatch timer disabled | U2 (actor hosts in the registry) |
| actor restarts AS2 / Colab | none | AS2 ractors jobs and Colab sims | U2 / U3 |
| gate evals at step N | run_keeper gates (once per threshold, `<run>/gates/`) | only for unregistered runs | done (U2) |
| site / showcase refresh | clashlab-site / -monitor / -showcase / -record timers | none: active attacker runs (AS2 + clash-sim) become showcase targets automatically; stale-example alarm (`featured_stale`, > 12 h) since 2026-10-13 | done (site-auto U1-U3) |
| model archive | AI-ModelArchive (2 h) | none known | - |
| disk space | AS1 C: < 20 GB: clashsim_watch deletes stale miniflare / wsl-crashes | AS1 G:/W:, AS2 /, clash-sim vhdx: no guard | U3 disk guards |
| relay health | clashsim_watch restarts `\AI-ClashSim-Attv3Relay` when `/run/clash/{jr_hub,jrcore_hub}.sock` are missing | AS1 `\AI-LLMRelay` (as2_llm_relay) has no watchdog (the relay pile-up that froze WSL); clashsim_watch re-runs the relay every 15 min while the jr hubs are held by LLM mode (sockets stay missing: churn, not a fix) | U3 |
| LLM mode idle off | llmmode-idle watcher (started by `on`) | if the watcher dies while LLM mode is on, nothing restarts it (LLM stays on, training held). Now visible: the keepers table shows llmmode **stale** | U3: keepers collector restarts the watcher (never turns LLM mode off) |
| ai-power | ai-power.service Restart=always + ai-server-2-watchdog | none | - |
| aq itself | LaunchAgent com.taiwong.agent-queue (KeepAlive, RunAtLoad); dead agents re-queued by `aq sweep` | Mac asleep / off: nothing runs | U3: `fallback: dsh` only for checks no keeper can do |
| Colab sessions expiring | none | sims die silently | U3 re-provision within the daily unit budget (or documented gap) |
| AS1 job queue | AI-JobQueue task (Running), AI-AdminWatchdog | - | - |
