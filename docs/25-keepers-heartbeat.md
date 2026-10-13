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

## Audit: what needs an agent today

| function | current keeper (deterministic) | gap (still needs an agent) | planned |
|---|---|---|---|
| training run restart / resume (gen2, jr*) | jr hubs: LLM-mode requeue reruns them with `JR_RUN_DIR` (resume from newest ckpt) after `llm-mode off`; pf: pf_watch (disabled) | a hub that stops stepping for any other reason (crash, failed job, gen2 hubs on clash-sim `attv3-gen2@*`) is restarted by nobody | U2 run keeper (registry, stall 15 min -> resume), gen2 only after attacker-owner ack |
| learner restarts (AS1) | AI-PfLearnerKeeper: one clashlearner per `state\pf_learners.json` entry (pf, core) | entries are hand-maintained; gen2/jr learners rely on `--learner-autostart` from the hub | U2 (registry entry carries the learner) |
| hub restarts | pf_watch (pf only, disabled); clashjobs retry | generic stall restart | U2 |
| actor restarts AS1 clash-sim | AI-ClashSim-Watch (`attv3-jractors@jr_hub/jrcore_hub`, distro ro/hang repair, relay) + jr-hostwatch on AS2 (0 b/s -> `--restart-actors`) | gen2 actor instances not in clashsim_watch's INSTANCES; attv3-actorwatch timer disabled | U2 (actor hosts in the registry) |
| actor restarts AS2 / Colab | none | AS2 ractors jobs and Colab sims | U2 / U3 |
| gate evals at step N | none | submitted by agents | U2 (`clashjobs --after` / step trigger, once per threshold) |
| site / showcase refresh | clashlab-site / -monitor / -showcase / -record timers | none: active attacker runs (AS2 + clash-sim) become showcase targets automatically; stale-example alarm (`featured_stale`, > 12 h) since 2026-10-13 | done (site-auto U1-U3) |
| model archive | AI-ModelArchive (2 h) | none known | - |
| disk space | AS1 C: < 20 GB: clashsim_watch deletes stale miniflare / wsl-crashes | AS1 G:/W:, AS2 /, clash-sim vhdx: no guard | U3 disk guards |
| relay health | clashsim_watch restarts `\AI-ClashSim-Attv3Relay` when `/run/clash/{jr_hub,jrcore_hub}.sock` are missing | AS1 `\AI-LLMRelay` (as2_llm_relay) has no watchdog (the relay pile-up that froze WSL); clashsim_watch re-runs the relay every 15 min while the jr hubs are held by LLM mode (sockets stay missing: churn, not a fix) | U3 |
| LLM mode idle off | llmmode-idle watcher (started by `on`) | if the watcher dies while LLM mode is on, nothing restarts it (LLM stays on, training held). Now visible: the keepers table shows llmmode **stale** | U3: keepers collector restarts the watcher (never turns LLM mode off) |
| ai-power | ai-power.service Restart=always + ai-server-2-watchdog | none | - |
| aq itself | LaunchAgent com.taiwong.agent-queue (KeepAlive, RunAtLoad); dead agents re-queued by `aq sweep` | Mac asleep / off: nothing runs | U3: `fallback: dsh` only for checks no keeper can do |
| Colab sessions expiring | none | sims die silently | U3 re-provision within the daily unit budget (or documented gap) |
| AS1 job queue | AI-JobQueue task (Running), AI-AdminWatchdog | - | - |
