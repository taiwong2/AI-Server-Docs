# Train guard (AI Server 2 timer, 2026-10-14)

Why: 2026-10-14 02:43Z the main attacker run (gen3) hit its 2M step cap and finished. The gen3zone A/B ended at its
gate and nothing else in the backlog was eligible, so both AI Server 1 3090s sat at 0 % for 3 h while the agents were
at a usage limit. The user asked: "can u ensure stuff is training always". The keepers each checked one thing, and none
of them checked whether every GPU was training.

| what | where |
|---|---|
| code | ClashEngineering `ops/strixhalo/train_guard.py` (stdlib, imports backlog.py), config `ops/train_guard.json` |
| live config overlay | AS2 `~/clash-jobs/state/train_guard_cfg.json` (keys win; `main` = the newest generation) |
| timer | AS2 user `train-guard.timer` every 3 min -> `train-guard.service` (`train_guard.py tick`) |
| log (actions, incidents) | AS2 `~/clash-jobs/state/train_guard.log` |
| state | AS2 `~/clash-jobs/state/train_guard.json`; site copy `~/clashlab-www/train_guard.json` (Overview "training now") |
| heartbeat | `~/clash-jobs/state/heartbeats/train_guard.json`, row `train_guard` in keepers.json (healed when stale) |
| pause one thing | `train_guard.py pause main 90m --why "..."` (keys main, main-learner, gpu0, gpu1, igpu, ab:ENTRY) |
| disable | `touch ~/.config/train-guard.disabled` on AS2 |

Each pass:

- **Main run** (gen3): its backlog arm entry never has a step cap (`GEN3_STEPS=0`, no `stop.steps`; the guard
  rewrites the overlay entry). Arm job ended -> `backlog retry` arm (+ learner) + one backlog pass, which resumes from
  the newest checkpoint. Running but no metrics row for 45 min -> cancel its AS2 proxy, and the backlog relaunches
  it. Held in the backlog -> reported, not resumed.
- **A/B arms**: stuck -> cancel (the backlog retries). An A/B arm that ended at its gate is left alone.
- **GPUs**: AS1 GPU0/GPU1 (nvidia-smi, util >= 30 % = training) and the AS2 iGPU (a running `attv3-as2train*` lane).
  Idle for 10 min -> a backlog pass now. If the GPU is still idle after that, the guard logs an incident
  ("backlog dry"). It never invents jobs, never launches a held entry and never takes a GPU an enabled
  AI-PfLearnerKeeper slot owns. The iGPU yields while LLM mode is on (LLM MODE TAKES PRECEDENCE; the guard never
  calls llm-mode).
- Every action key has a 20 min cooldown and a cap of 6 actions per 6 h. After that its row reads "needs a human".

The attacker-owner aq task reads `train_guard.py status` and the log every cycle. Full doc: ClashEngineering
`docs/attacker/TRAIN_GUARD.md`.

## Escalation: the Codex fixer (2026-10-14)

The guard fixes what it can and never invents work. What it cannot fix goes to Codex: `train_guard.py incidents
--json` lists the open incidents with a stable `id`, a `kind` (main-down / gpu-idle / backlog-dry / gpu-unreachable /
ab-stuck / data-missing: a job worktree lacks gitignored data, doc 15 "Worktree data"), `needs_human`, `paused` and the `actions` it tried. The Mac's `aq trainwatch` (LaunchAgent, every 3 min)
reads it and, when the main run is down >= 10 min, a GPU idle >= 15 min, the guard says "needs a human", or the guard
is stale, queues ONE `codex exec` task (model gpt-5.6-luna) with a fixed playbook; one fixer at a time, one per incident
per 60 min, 6 a day. Fixers write `train_guard.py note ...` lines into this log. Details and the rules table:
[22-agent-queue.md](22-agent-queue.md#runnercodex-and-trainwatch-codex-gets-training-going-again-2026-10-14), repo
`docs/attacker/TRAIN_GUARD.md`.

## CURRENT: the canonical plan (2026-10-14)

User: "you need to make codex know what the most recent thing is". A Codex fixer had cloned a superseded A/B
(gen3zone-as2 -> gen3zone2-as2) onto the AS2 iGPU that was reserved for the gen4 prototype; the reservation existed
only in aq notes.

| what | where |
|---|---|
| code | ClashEngineering `ops/strixhalo/current.py` (also `train_guard.py current ...`), seed `ops/current.json` |
| canonical file | AS2 `~/clash-jobs/state/current.json` (`plan` + `live` + `history`) and `CURRENT.md` next to it; site copy `~/clashlab-www/current.json` |
| repo mirror | `docs/attacker/CURRENT.md` (`current.py export <worktree>`, commit it after a plan change) |
| read | `ssh ai-server-2 python3 ~/ClashEngineering/ops/strixhalo/current.py show` |
| edit the plan | `current.py set main.run ...`, `set next.gen4.status ...`, `reserve igpu --for gen4 --until 12h --why ...`, `unreserve igpu`, `supersede gen3zone2-as2 --why ...`, `unsupersede ID` (each logged in the guard log as `current (<who>): ...`) |

- The guard rewrites the `live` part every pass (runs, steps, GPU rows, incidents, pauses, running backlog jobs, gate
  verdicts) and CURRENT.md with it.
- A reserved resource (`igpu`, `gpu0`, `gpu1`) idle = row `reserved for <gen> until ...` (level ok): no backlog pass, no
  incident, no Codex fixer. Expired reservations are shown as EXPIRED and not enforced.
- The backlog never launches, releases, retries or re-adds a superseded id / glob and launches nothing on a reserved
  resource unless the entry id matches the reservation's `allow` globs (default `<gen>*`). `backlog.py status` lists
  those as `superseded` / `reserved` rows.
- `train_guard.py incidents --json` carries `reservations`, `superseded`, `current_md`; the Mac trainwatch embeds
  CURRENT.md in every fixer prompt and skips incidents on reserved resources ([22](22-agent-queue.md)).
- Agents (AGENTS.md rule 11, the attacker-owner task) update it when they start, stop or retire a run or take /
  release hardware.
