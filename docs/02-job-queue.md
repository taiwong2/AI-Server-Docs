# The job queue

`C:\AI-Server\scripts\jobqueue.py` is how work gets onto this machine. It is
also what decides when the machine sleeps — those two things are the same
question ("is there work?") and so they live in one place.

## Why you should use it instead of just running the thing

A queued job:

- survives your session ending, the box suspending, and a reboot
- **wakes the machine** if it is asleep and the job is due
- is retried if the runner dies mid-run
- writes its own log you can read afterwards
- is cleared from the queue when it finishes, so the box can sleep again

Run something inline and it dies with your session.

## Submitting

```bash
Q="C:/AI-Server/scripts/jobqueue.py"

# now
python $Q submit --kind image --arg Src="C:\pics\a.jpg" --arg Out="C:\AI-Server\out\a"

# at a wall-clock time (HH:MM = the next such time; wakes the box)
python $Q submit --kind claude --arg Prompt="run the nightly check" --at 03:00

# in N minutes
python $Q submit --kind shell --arg cmd="nvidia-smi" --in-minutes 30

# jump the line
python $Q submit --kind image --arg Src="..." --priority 10
```

From python:

```python
import sys; sys.path.insert(0, r"C:\AI-Server\scripts")
import jobqueue
jobqueue.submit(kind="image", args={"Src": r"C:\pics\a.jpg"})
```

## Watching

```bash
python $Q list      # queue, plus the last 5 done and failed
python $Q status    # is it busy, when does it next wake, WHY is it not asleep
python $Q cancel <job-id-prefix>
python $Q tick      # run everything due right now, then exit (does not sleep)
```

Per-job output: `C:\AI-Server\logs\jobs\<job-id>-<kind>.log`.
Queue decisions: `C:\AI-Server\logs\jobqueue.log`.

## Job kinds

Kinds are **files**, not a table in the code. `scripts\jobkinds\<kind>.ps1` or
`.py`, and every `args` key arrives as `-Name Value` (ps1) or `--name value`
(py). Adding a capability needs no change to the broker.

| Kind | What it does |
|---|---|
| `image` | background extension + super-resolution — see [Imaging](04-imaging.md) |
| `claude` | headless `claude -p` in a working directory you name |
| `shell` | a PowerShell command (`--arg cmd="..."`) |
| `clashlearner` | ClashLab PPO learner for the Clash RL system: GPU lease (8 GB) + HTTP on :8890, exits after 20 min idle or 170 min; `-Ce` picks the checkout (attacker runs: lane `attacker`, `ce_att`) — see [AlphaClash workspace](14-alphaclash-workspace.md) |
| `clashlink` | ClashLink for the Clash RL league: `Role=learner` = PPO learner behind the ClashLink hub (GPU lease 8 GB, lane `league`, exits idle / 170 min / on a shutdown message); `Role=hub` = the hub as a job (fallback only: the hub normally runs as the scheduled task `AlphaClash-ClashLink`, so it does not hold a lane) — see [AlphaClash workspace](14-alphaclash-workspace.md) |

### Writing a new kind

```powershell
# C:\AI-Server\scripts\jobkinds\mykind.ps1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string] $Src, [string] $Out)
$ErrorActionPreference = 'Stop'
# Resolve interpreters and profile paths EXPLICITLY -- this runs as SYSTEM.
$py = 'C:\Users\poopl\miniconda3\envs\ai\python.exe'
& $py 'C:\path\to\real\work.py' --src $Src --out $Out
exit $LASTEXITCODE
```

Rules for a job kind:

- **Exit non-zero on failure.** The queue reads your exit code; a handler that
  swallows errors and exits 0 makes a broken job look done.
- **Never prompt.** A SYSTEM task has nobody to answer; it hangs forever.
- **Keep the algorithm in a versioned repo**, not in the handler. The handler is
  a launcher so the queue does not need to know where the repo is checked out.
- **Resolve paths explicitly** (AGENTS.md rule 7).

## Lanes (added 2026-10-08)

By default the queue runs **one job at a time**. A job may ask for a **lane**; at most one job runs per lane,
and at most `max_lanes` lanes (state\jobqueue.json, now 4) run at once. Jobs without a lane are in `main`,
so anything that does not opt in behaves exactly as before.

```bash
python $Q submit --kind shell --arg cmd="..." --lane gpu0      # next to whatever runs in main
python $Q list                                                 # shows lane= per job
```

```python
jobqueue.submit(kind="shell", args={"cmd": "..."}, lane="gpu0")
```

- The runner starts each lane's job in its own thread; locking, retries, timeouts and the sleep gates are unchanged
  (running jobs still keep the box awake).
- The queue does **not** pick GPUs. Two GPU jobs in different lanes must still each take a `gpulease`, which places
  them on different cards or makes the second wait.
- Lanes in use by the Clash RL system: `main` (BaseFinder training), `gpu0` (parsing / designer GPU work),
  `designer`, `cpu` (scrapers, synthetic data); since 2026-10-09 also `attacker`, `designer_ar`, `renderer`,
  `scrape` and `league` (the league's learner + designer jobs, one after the other), `bf4a` / `bf4b` (BaseFinder
  grid18_v4 training and sharded parsing), `synth5a` / `synth5b`, `bf5a` / `bf5b` / `bf5lvl` (BaseFinder v7 grid18_v5 /
  level18_v2 training and evals) and `bf5p0`..`bf5p3` (parsed18_v5 shards). The ClashLink hub left the queue
  (scheduled task `AlphaClash-ClashLink`) because a hub job held a lane permanently; with `max_lanes` = 5 a new lane
  often waits for another agent's lane to finish.
- `cancel` on a RUNNING job kills it but the queue may retry it (it came back as `try 2/2` and blocked its lane
  waiting for a gpulease); cancel it a second time once it shows the new try.
- Why: on 2026-10-08 the single queue left the second RTX 3090 and ~80% of the CPU idle while one training job held
  the queue for 160-minute chunks.
- Restarting the runner (`taskkill` the pid in `state\queue\.runner.pid`, then `schtasks /run /tn \AI-JobQueue`)
  leaves running children alive; the new runner treats them as foreign and reaps them as "runner died" when they
  exit, which requeues them unless `max_attempts` is reached. Set `max_attempts = attempts` on such jobs first if a
  rerun is not wanted. Backup of the single-lane version: `scripts\jobqueue.py.bak-20261008-prelanes`.

## Job lifecycle

```
submit -> queued -> running -> done      (archived to state\queue\done\)
                            -> failed    (archived to state\queue\failed\)
                            -> queued    (retry, up to max_attempts)
```

A `running` job whose PID is gone, or which exceeds `job_timeout_minutes`
(default 180), is requeued — or failed if it is out of attempts. This happens at
the top of every tick, so a killed runner never wedges the queue.

## Configuration

`C:\AI-Server\state\jobqueue.json`, re-read every tick — no restart needed.

| Key | Default | Meaning |
|---|---|---|
| `grace_minutes` | 8 | queue must stay empty this long before sleeping |
| `heartbeat_minutes` | 20 | how often it wakes to check for remote work |
| `poll_seconds` | 10 | how fast a new job starts while awake |
| `input_idle_minutes` | 15 | console idle time before "unattended" |
| `sleep_enabled` | true | false = manage the queue but never suspend |
| `remote_inbox` | false | drain a Supabase table of remote submits |
| `busy_ports` | `[25565]` | a listening port here blocks sleep |
| `max_attempts` | 2 | retries per job |
| `max_lanes` | 3 (set to 4) | lanes that may run at once (see Lanes) |
| `job_timeout_minutes` | 180 | a job outliving this is killed |

**Write this file without a BOM.** PowerShell's `Out-File -Encoding utf8` adds
one; the reader tolerates it now, but a BOM once made the whole config
unreadable and the runner silently fell back to defaults while a script printed
"ARMED". Use:

```powershell
[IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
```

## Remote submits (from a machine that is not on the LAN)

Off by default. When `remote_inbox` is true, the runner drains a Supabase
`job_inbox` table on every tick and every heartbeat wake, so a device anywhere
can queue work even while the box is asleep — it runs within
`heartbeat_minutes`.

```sql
create table job_inbox (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  args jsonb not null default '{}'::jsonb,
  not_before timestamptz,
  requester text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  claimed_by text
);
alter table job_inbox enable row level security;   -- no anon policy
```

Creds go in `C:\AI-Server\state\credentials\supabase.env` (`SUPABASE_URL`,
`SUPABASE_SERVICE_KEY`), never in a repo.

**A row in this table becomes a command on this machine.** `kind: claude` runs
an agent against a repo; `kind: shell` runs PowerShell. Write access to
`job_inbox` is equivalent to shell access here.

Rows are claimed *before* they become local jobs, so a crash between the two
loses a job rather than running it twice — the right trade when a double-run
could mean two agents editing one repo.
