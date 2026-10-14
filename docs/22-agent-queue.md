# Agent queue: work that survives Claude usage limits

> Mac only. Installed 2026-10-11. Source: [`scripts/agent-queue/`](../scripts/agent-queue/) (`aq`, the runner
> LaunchAgent, `install.sh`, `test.sh`). Installed copy: `~/.claude/agent-queue/bin/aq`, on PATH as `aq`.

## Why

On 2026-10-11 at about 22:10 UTC the Claude session limit hit. Every background agent died mid-task, including the one
moving the attacker training run (pf), so pf sat dead for 4+ hours until a human started a new session. The limit
resets at a known time (the 429 text says e.g. `You've hit your session limit · resets 9:20pm (America/Chicago)`, and
the transcript record carries `quotaLimits.resetsAt` as an epoch), so nothing needs a human to restart it.

**Critical training must not depend on agents at all.** Training runs belong under supervised units with their own
watcher (systemd / clash-jobs on AI Server 2, the job queue on AI Server 1), so they restart without any agent. The pf
recovery work (2026-10-11) puts pf under supervised units plus a watcher. The queue is for *agent* work: it brings
agents back after a limit. It is not what keeps training alive.

## What it is

```
~/.claude/agent-queue/
  tasks/<id>.json    one task: prompt, cwd, priority, status, attempts, limit_hits, session_id, runner, fallback, ...
  logs/<id>.log      per-task log (command, stderr, output, exit) + logs/<id>.<n>.<mode>.out per attempt
  notes/<key>.md     resume notes written with `aq note`
  state.json         global: blocked_until (Claude limited until), why, paused, sweep_since
  runner.log         the runner's own log; hooks.log = raw StopFailure hook input
```

- **Runner**: LaunchAgent `com.taiwong.agent-queue` (`aq run`, KeepAlive). A Python poll loop, no compute. It runs at most
  2 tasks at once (`AQ_MAX_PARALLEL`), highest priority first, as `claude -p --output-format json` in the task's cwd with
  the user's own settings and permission mode (pass `--permission-mode` / `--model` / `--effort` per task to override).
  A new task gets `--session-id <uuid>`, so the runner knows the session it may need to resume.
- **Usage limit**: when a run ends with a limit error, the runner reads the reset time (transcript
  `quotaLimits.resetsAt`, else the `resets 9:20pm (TZ)` text, else +30 min), sets `blocked_until = reset + 90 s`, and
  puts the task back to **pending** (`limit_hits += 1`, attempts unchanged). It starts no Claude task until then, so
  there is no hammering. At most one Claude start per 20 s tick, so one fresh 429 stops the rest. After the reset the task
  continues **the same session** (`claude -p --resume <session>` with "continue from where you stopped" plus its notes).
- **Other errors**: retry after 5, 10 min, then `failed` (3 attempts by default). Timeouts: 3 h claude, 30 min dsh.
- **Fallback during outages**: `--fallback dsh` tasks run on **dsh** (Flash-Next) while Claude is blocked; `--runner dsh`
  tasks always do. dsh runs headless with `DSH_NO_LLM_MODE=1` (it never turns on LLM mode, so it never evicts AI Server
  2's Clash jobs: `flash-next` goes to AI Server 2 if its model is up, else AI Server 1), in `dsh-work/<id>/` unless the
  task gave `--cwd`. It gets a conservative preamble (read-only first, only the actions the task authorises, no deletes).
  dsh can ssh to both servers.
- **Session-death hook**: `~/.claude/settings.json` has a `StopFailure` hook (matcher `rate_limit`) running `aq hook`.
  StopFailure fires instead of Stop when an API error ends a turn. The hook sets the global block and queues a resume:
  a background agent → a `resume-agent` task, the interactive session → a `resume-session` task that **forks** the
  session (`--resume <id> --fork-session`, so it never writes into the transcript you have open).
- **Sweeper** (backup for the hook, every 5 min): scans `~/.claude/projects/*/*/subagents/agent-*.jsonl` and session
  transcripts for ones whose last record is a `rate_limit` error after the queue was installed, and queues a resume for
  each one not already queued.
- **Superseded check**: before starting a resume task, the runner checks whether that agent/session already produced a
  normal turn after the failure (someone resumed it by hand). If so it marks the task done ("superseded").

A `resume-agent` task is a fresh headless Claude in the agent's cwd, told to read the agent's notes
(`aq notes --session <parent> --agent <id>`) and the tail of its transcript (`aq transcript <path> --last 60`), re-check
live state, and finish the work. (Background agents cannot be resumed from the CLI by id, so this is how they continue.)

## Commands

```bash
aq add "prompt" [--cwd DIR] [--label NAME] [-p 8] [--fallback dsh | --runner dsh] [--at +30m|21:20] [--every 30m]
aq add --resume-agent <agent_id> "message for it"     # continue a dead background agent
aq add --resume <session_id> [--fork] "message"       # continue a Claude session headlessly
aq list [-a]          # queue + runner + block state
aq show <id|label>    # details, history, result, notes
aq log <id> [-f]      # per-task log
aq cancel <id>        aq retry <id> [message] [--fresh]
aq note <task|label> "state / next steps"     # checkpoint (agents: at major steps, before long waits)
aq notes [key] [--session SID] [--recent 12h]
aq transcript <path|agent_id|session_id> [--last 60] [--first 5]
aq status | aq block +2h | aq unblock | aq pause [--off] | aq sweep | aq gc
```

**Manual one-liner** after a limit, if the hook/sweeper missed an agent:
`aq add --resume-agent <agent_id> "continue; the limit has reset"` (the agent id is in the task notification or the
`subagents/agent-<id>.jsonl` file name).

**Watchdog tasks for dsh** (example, read-only):
```bash
aq add --runner dsh --every 30m --label pf-check "Read-only: ssh ai-server-2 '~/ClashEngineering/.venv/bin/python \
 ~/ClashEngineering/ops/strixhalo/clashjobs.py list'; report ALIVE/DEAD for the pf run with the job lines."
```
Give a dsh task the exact documented recipe if it may act (e.g. the restart checklist in the Clash handoff) and say
which actions are allowed. No pf watchdog is installed by default: pf's watcher is a supervised unit on the servers.

## Checkpoint convention (agents)

Rule in `~/.claude/CLAUDE.md` and ClashEngineering `AGENTS.md`: before a long wait and after each major step, run
`aq note <task-label> "done: ...; next: ...; state: ..."` (the note records the session id and cwd). A resumed run reads
these first. Runner tasks are told their own id (`aq note <id>`).

## Operate

```bash
scripts/agent-queue/install.sh      # install / update (copies aq, LaunchAgent, adds the hook; backs up settings.json)
scripts/agent-queue/test.sh         # offline test: fake claude 429 -> wait -> resume; hook, sweeper, dsh fallback
launchctl bootout gui/$(id -u)/com.taiwong.agent-queue        # stop the runner
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.taiwong.agent-queue.plist   # start it
```

Test results 2026-10-11: `test.sh` passes (limit at t+2 s, no Claude call for the 26 s until reset, then `--resume` of
the same session, done; hook and sweeper each queued a resume; a `fallback=dsh` task ran on dsh while blocked). Live: a
real `claude -p` task ran from the LaunchAgent; a real dsh fallback task (read-only pf check over ssh) ran end to end
while Claude was blocked.

Limits: the hook's exact input for background agents is not documented (it logs raw input to `hooks.log`; the sweeper
covers it either way). A forked `resume-session` and you typing in the same conversation can both run; `aq cancel` it
if you come back first (or it is marked superseded automatically if you resumed before it started).

## Session budget: handoffs instead of huge resumes (2026-10-12)

The user's rule is to reset sessions regularly, hand off between them, and keep workflows small.
- **The runner never resumes a session whose transcript is over 3 MB** (`AQ_SESSION_MAX_MB`). This covers a task's own
  earlier attempt and `resume-session` tasks. The task starts a fresh session instead. Its prompt carries a HANDOFF
  header: the old transcript path (read with `aq transcript ... --last 40`), the task's `aq note`s, and the original task.
- **The PREAMBLE tells every queued agent to work in chunks of about 90 min.** At a clean point it writes `aq note`
  done / next / state, queues the rest as a fresh `aq add` with the handoff in the prompt, and ends. Its subagents
  return short handoffs, not logs.
- **Dead background agents** were already resumed fresh (`resume-agent` tasks read notes and the transcript tail).
- Backup of the runner before the change: `~/.claude/agent-queue/bin/aq.bak-20261012-handoff`. Restart the runner after
  editing it: `launchctl kickstart -k gui/$(id -u)/com.taiwong.agent-queue`, and kill a leftover `aq run` python if
  it reports "a runner is already running".

## runner=codex and trainwatch: Codex gets training going again (2026-10-14)

User: "when something is idle can you detect it deterministically and launch codex and use luna as a model and just
tell it to get stuff training again".

**runner=codex** (`aq add --runner codex ...`): the task runs as `codex exec -m gpt-5.6-luna -s workspace-write -c
sandbox_workspace_write.network_access=true -c approval_policy="never" --skip-git-repo-check -C
~/.claude/agent-queue/codex-work/<id> --json -o <log>.last`, with `--add-dir` for `~/.claude/agent-queue` (aq note),
`~/Documents/ce-wt` (agent worktrees), `~/Documents/ClashEngineering/.git` (worktree / merge metadata) and
`~/Documents/AI-Server-Docs`. The shared checkout itself stays read-only to it. ssh to ai-server / ai-server-2 works
inside that sandbox. The prompt starts with `CODEX_PREAMBLE`, the hard rules Codex would not otherwise know: no
ClaudeHarness, never TPC (TPC2 = AS1 is fine), never `llm-mode off` (LLM takes precedence), no compute on the Mac,
AGENTS.md git rules with no Co-Authored-By, no secrets in output, Colab <= 25 units/day, gen3 (newest) gets the most
compute, never delete checkpoints / run data, the existing tools before ad-hoc kills, `aq note` + `train_guard.py note`.
Rule 12 (2026-10-14): Codex never creates backlog entries (no `backlog.py add`, no new ids, no clones of finished A/B
arms): it only retries / restarts EXISTING entries of the main run or the next generation that are not held and not
superseded. The gpu-idle / backlog-dry playbooks say the same: nothing eligible -> note and stop, do not invent work.

**READ CURRENT FIRST** (2026-10-14, after a fixer cloned the superseded gen3zone-as2 into gen3zone2-as2 on the AS2
iGPU reserved for gen4): the canonical plan is AI Server 2 `~/clash-jobs/state/current.json` + `CURRENT.md`
(ClashEngineering `ops/strixhalo/current.py`, repo mirror `docs/attacker/CURRENT.md`, doc 27): main run, next
generation, hardware RESERVATIONS, SUPERSEDED runs / entries, gates, the standing rules. CODEX_PREAMBLE opens with it,
every trainwatch prompt embeds CURRENT.md as read at launch (from `incidents --json` `current_md`, else a second ssh
`current.py show`), and the backlog itself refuses to launch / release / retry / re-add superseded entries or to put
anything else on a reserved resource.
The final message (`-o`) is the task's result; the JSONL event stream is in `logs/<id>.<n>.codex.out` and the log.
Default timeout 45 min (`--timeout`). Overrides: `AQ_CODEX_BIN`, `AQ_CODEX_MODEL`, `AQ_CODEX_DIRS`. dsh and codex tasks
have their own slots (`AQ_MAX_PARALLEL_OTHER`, 2), apart from claude's `AQ_MAX_PARALLEL`.

**trainwatch** (LaunchAgent `com.taiwong.trainwatch`, `StartInterval` 180 s, `/bin/bash -c "/usr/bin/python3
~/.claude/agent-queue/bin/aq trainwatch"`; aq lives under ~/.claude, so no ~/Documents launchd EPERM): one ssh read of
`train_guard.py incidents --json` on AI Server 2 (falls back to the raw `train_guard.json`). The rule is deterministic,
no LLM decides:

| incident | due when |
|---|---|
| `main-down` (gen3 arm not stepping) | open >= 10 min |
| `gpu-idle`, `backlog-dry`, `gpu-unreachable` (AS1 GPU0/1, AS2 iGPU) | open >= 15 min (after the guard's own backlog pass) |
| any incident whose status says "needs a human" | at once |
| `guard-stale` (guard state > 20 min old) | 3 passes in a row (AS2 may just have woken from suspend) |
| `ab-stuck`, `other` | only with "needs a human" |
| key paused (`train_guard.py pause`) | never: an agent is doing manual ops |
| idle GPU reserved in CURRENT (`current.py reserve igpu --for gen4 ...`; incident `reserved`, or key in `reservations`) | never: idle by plan (the guard does not even open one) |

Due incidents -> ONE task `label=train-fixer runner=codex priority 8 max_attempts 1 timeout 45m`, prompt = CURRENT.md
(fresh from AS2) + the incidents (id, kind, status, what the guard tried) + the playbook per kind + fixed steps (diagnose with these commands,
fix with the documented tools, verify GPU util > 50 % and steps advancing, report). Dedupe and caps: no launch while a
`train-fixer` task is pending/running; one launch per incident id per 60 min (`AQ_TW_COOLDOWN_MIN`); 6 per 24 h
(`AQ_TW_MAX_PER_DAY`). AS2 unreachable (asleep): no launch, logged on the 1st/5th/every 20th failure. It always uses
codex, even when Claude is available (the user asked for codex for this ops job).

Logs: `~/.claude/agent-queue/trainwatch.log` (every launch and each distinct skip), state `trainwatch.json`, and every
launch also lands in the AS2 guard log. Commands:
```
aq trainwatch -v                         # one pass now
aq trainwatch --dry-run                  # print the task it would queue
aq trainwatch --dry-run --state-file F   # against a fake guard state (tests)
touch ~/.claude/agent-queue/trainwatch.disabled   # off
aq list | grep train-fixer; aq show train-fixer   # the newest fixer and its report
```
Tests: `scripts/agent-queue/test.sh` PASS 3 (fake codex: flags, preamble, last message = result) and PASS 4 (fake
guard state: idle GPU 20 min + main needing a human -> exactly one fixer; a 2-min-old GPU incident is not in it; the
second pass is deduped). Smoke 2026-10-14: a read-only codex task from the launchd runner ran `train_guard.py status`
over ssh on AS2 and nvidia-smi on AS1, wrote an aq note, and reported model gpt-5.6-luna (408 s).

Live since 2026-10-14 19:14Z. First incident `igpu@1791983969` (AS2 iGPU idle ~6.4 h, guard 'needs a human'):
fixer 1 (`20261014-141404-404f`) found the newest-gen `gen3eff-as2` learner stuck behind AS2 memory admission, raised
its priority 60 -> 80 and cancelled nothing; still queued at its bounded end. The 60-min cooldown held, then fixer 2
(`20261014-151521-40ff`, 2/6 that day) cancelled a stale dsg24 report and a broken offeval sync to free admission. It
found the AS2 worktree was missing validation artifacts (pinned APK, `x86_oracle_linux_imports.json`,
`x86_env_addrmap.json`), copied them from AS1 with the hashes checked, and restarted cleanly: job 817597003473 trains
(iGPU 100 %), the guard logged `resolved igpu after 7.2 h`, AS1 main kept advancing. No human needed.

Install gotcha found on the way: `launchctl bootout` stops the runner's /bin/bash parent, but a python runner busy in a
long call can survive and keep the runner lock (the new one then exits "a runner is already running" in a loop).
install.sh now TERMs, then KILLs, any leftover `aq run`.
