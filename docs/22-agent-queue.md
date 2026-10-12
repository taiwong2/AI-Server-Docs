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
