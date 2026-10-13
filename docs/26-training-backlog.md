# Training backlog (AI Server 2 timer, 2026-10-13)

Why: when Claude usage runs out, the GPUs and CPUs should keep training instead of sitting idle (the user,
2026-10-13). Agent queues (aq) need Claude; this does not.

| what | where |
|---|---|
| code | ClashEngineering `ops/strixhalo/backlog.py` (stdlib), registry `ops/train_backlog.json` |
| timer | AS2 user `train-backlog.timer` every 5 min -> `train-backlog.service` (`backlog.py tick`) |
| live overlay (no merge needed) | AS2 `~/clash-jobs/state/train_backlog.json`, edit with `backlog.py add ENTRY.json` / `remove` / `hold` / `release` |
| state | AS2 `~/clash-jobs/state/backlog_state.json` (running, next, done, failed, last decision, slots); copy `~/clashlab-www/backlog.json` |
| decision log | AS2 `~/clash-jobs/state/backlog_log.jsonl` (launch, done, failed-retry, failed, launch-failed, would-launch) |
| heartbeat | `~/clash-jobs/state/heartbeats/train_backlog.json`, row `train_backlog` in keepers.json |
| disable | `touch ~/.config/train-backlog.disabled` on AS2 |

Each pass: refresh the launched entries' jobs, then start the highest-priority entry whose dependencies hold and whose
slot is free (at most 3 per pass, one per host):

- AS1 GPUs: cards with < 1.5 GB used (nvidia-smi over ssh) -> AS1 `jobqueue.py submit --kind ...` (requester backlog).
- clash-sim: runner budget 14 minus running and queued jobs' CPUs, backlog's own <= 12 -> `clashsim submit`.
- AS2: while LLM mode is on, only what clashjobs would admit anyway (0-CPU / stay lanes); it never calls `llm-mode` and
  never preempts the LLM. Entries with `"launcher": ["clashjobs", "clashsim"]` go to clash-sim instead.
- Colab: only from a host with the colab CLI (the Mac), <= 20 units/day. Not launched from AS2.

It never restarts a run: `run_keeper.py` (run-keeper.timer) resumes registered runs and submits their gate evals.
New entries are `mode: dry-run` until checked (`backlog.py status` shows the command they would run).

Commands (AS2): `python3 ~/ClashEngineering/ops/strixhalo/backlog.py status | tick --dry-run | validate`.
