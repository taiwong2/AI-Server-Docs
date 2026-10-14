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
