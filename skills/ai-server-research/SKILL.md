---
name: ai-server-research
description: Run deep technical research on Tai's AI server using the local Qwen model, one topic per queued job, with findings written to disk and posted to a Discord channel. Use when asked for a literature sweep, a survey of a technical area, arXiv research, or any long unattended research the local model should do instead of burning API tokens.
---

# Deep research on the local model

Free (no API tokens), slow (~10-25 min a topic), and it runs unattended. Use it
for breadth; use a Claude subagent when the answer must be *right* the first
time. The two complement each other — run both and reconcile.

## Run it

```bash
Q="C:/AI-Server/scripts/jobqueue.py"
python $Q submit --kind qwenresearch --arg TopicId=01
python $Q submit --kind qwenresearch --arg TopicId=02 --arg ReasoningEffort=xhigh
```

Each job = **one topic**, which keeps a run far inside the queue's
`job_timeout_minutes` (180) and gives every topic its own log, its own retry and
its own result file. Do not batch ten topics into one job; one bad topic then
takes the whole run down with it.

- Driver: `C:\AI-Server\scripts\research_qwen.py` (topics are a dict at the top)
- Handler: `C:\AI-Server\scripts\jobkinds\qwenresearch.ps1`
- Output: `C:\AI-Server\out\llm-efficiency\<id>-<slug>.md`, and posted to Discord
- Log: `C:\AI-Server\logs\jobs\<job-id>-qwenresearch.log`

## Why it is built this way

**One session per topic.** A shared session across topics blows the context
window and each topic gets slower and vaguer than the last. A fresh session per
topic keeps every one sharp.

**No GPU lease.** Inference goes to the model LM Studio already holds resident,
so this job allocates no VRAM of its own — there is nothing to lease. What the
long run actually needs is for the box not to sleep, and a runnable job is
itself a sleep blocker. Take a lease when *you* allocate VRAM, not when you call
someone else's server.

**The handler checks LM Studio before starting.** If `:1234` is not answering,
or the expected model is not loaded, it throws immediately instead of failing
slowly and obscurely twenty minutes in. Verify the effect, not the return path.

**A short answer exits non-zero.** Under 400 characters is treated as failure so
the queue retries, rather than archiving a stub as `done`.

## Writing the prompt is most of the work

A 27B local model needs the method spelled out. The driver's `METHOD` block is
the reusable part — copy its shape for new research:

- Name the search tools and *how* to use them. For arXiv, hit the API directly
  and **quote multi-word phrases** or it silently ORs the words:
  `http://export.arxiv.org/api/query?search_query=all:%22speculative+decoding%22&max_results=8&sortBy=submittedDate&sortOrder=descending`
- Demand primary sources; a blog only where no paper exists.
- **Forbid invention explicitly.** "Never invent an arXiv id, a number or a
  title. Write 'not verified' rather than guessing." Without this line a small
  model will produce plausible, wrong citations — the single biggest failure
  mode here.
- Fix the output format field by field (mechanism / measured gain + baseline /
  cost / adoption / citation). Open-ended prompts return marketing prose.
- Set `QWEN_REASONING_EFFORT=medium` for research. The loop default is `low`,
  which is tuned for chat latency, not for thinking.

## Verify before you trust

Local-model output is a **draft**. Spot-check arXiv ids resolve and that reported
numbers appear in the actual paper before repeating them anywhere. The handbook's
rule 5 applies hardest here: a fluent survey full of invented citations looks
exactly like a good one.

## Watching a run

```bash
ssh ai-server "python C:/AI-Server/scripts/jobqueue.py list"
ssh ai-server "powershell -NoProfile -Command \"Get-Content C:\AI-Server\logs\jobs\<id>-qwenresearch.log -Tail 25\""
```

Silence in the log is usually **buffering, not a hang** — check the process is
alive and that `C:\AI-Server\logs\qwen-agent.log` is gaining tool-call lines
before concluding it is stuck. A first model call at medium effort can take
several minutes before anything prints.

## Do not

- Do not run research inline over ssh; it dies with the connection.
- Do not raise `MAX_TOOL_ITERATIONS` to "fix" a slow turn — the turn is bounded
  by `TURN_TIME_BUDGET_SEC` (1200s), and a partial answer is saved to the session.
- Do not paste local-model citations into anything user-facing unverified.
