# Best practices

These are not style preferences. Each one is here because ignoring it cost real
time on this machine.

## Verify the effect, not the return path

The most expensive class of bug here is **something reporting success while
doing nothing**. Every one of these happened:

- `Register-ScheduledTask` fails *non-terminatingly* when unelevated. It writes
  "Access is denied" to stderr while the surrounding script prints its success
  string — so a power manager announced it had armed a wake timer that did not
  exist. A box that sleeps on a wake that no-ops never comes back.
- A config file with a byte-order mark made a reader throw, fall back to
  hardcoded defaults, and report itself configured. A test script printed
  "ARMED" while nothing was armed.
- A face detector, an edge-quality gate, and a 12B vision judge each certified
  output a human immediately rejected.

**Read the thing back.** Query the task. Re-parse the file. Look at the image.
A gate that cannot fail is not a gate.

## Observe a gate in both states before trusting it

"It correctly reports blocked" proves nothing when the blocker is permanently
present.

A sleep gate here called `query session` — which does not exist on Windows Home,
so it threw into a bare `except` — and then fell through to `Get-Process
sunshine`, which is a resident service and therefore always running. The gate
returned "someone is using the machine" forever and the box would never have
slept. It looked correct throughout development, because a session genuinely was
attached the whole time.

The test that matters is watching a gate go **clear**.

## A threshold a metric can land exactly on is a correctness decision

The idle monitor gated on `$gpu -lt 3`. An idle 3090 driving a display reports
**exactly 3%** every few minutes, `3 -lt 3` is false, and a single sample reset
the entire idle ladder. The sleep tier at 45 minutes was unreachable for months.
Nothing errored. Nothing logged a warning.

`-le` versus `-lt` mattered. So did the second half: **one sample must not undo
accumulated state.** The reset now needs several consecutive busy polls.

## Measure the real question, not a proxy

"Is the GPU under 3%" is a proxy. "Is there work queued" is the actual question
and has an exact answer. Moving the sleep decision from the first to the second
is what made it work at all.

## Paths resolve differently for scheduled tasks

The queue runs as SYSTEM, whose profile is
`C:\WINDOWS\system32\config\systemprofile`. `$env:USERPROFILE`, `$HOME`,
`%APPDATA%`, `~` all silently change meaning. A job that passes every by-hand
test can fail 0.2s in when the runner picks it up. That has happened twice here
— once for a conda interpreter, once for a per-user CLI and its credentials.

Resolve explicitly. Test as the account that will run it.

## SYSTEM tasks are invisible to unelevated queries

`Get-ScheduledTask AI-JobQueue` returns nothing from a normal shell while the
task is `Running` and perfectly healthy, and `Win32_Process` hides its command
line. This sent one session chasing a crash that had not happened. Query through
an elevated path before concluding a SYSTEM service is dead.

## Do not let two things own one decision

Two runners both reaching a sleep decision, or an installer and a runner both
starting tasks, is a bug waiting for a race. The queue runner is single-instance
via a PID file, and the idle monitor lost its sleep tier when the queue gained
one.

## Prefer the filesystem to a daemon

The queue and the lease broker are directories of JSON files. No service, no
port, no schema migration. Any language can read them, a human can `type` them,
and a crash leaves inspectable state instead of a lost in-memory queue. Every
item records its owner PID so anything can reap the dead.

## Fail closed on anything that could strand the machine

The runner refuses to sleep unless it has already armed a way back. Staying
awake wastes watts; sleeping without a wake means someone walks to the machine.

## Write down what cost you an hour

[Troubleshooting](08-troubleshooting.md) exists so the next agent does not pay
for the same discovery. If a rule in [AGENTS.md](../AGENTS.md) turns out to be
wrong, fix the rule rather than working around it silently.
