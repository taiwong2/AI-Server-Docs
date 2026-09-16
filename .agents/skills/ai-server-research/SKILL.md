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

Each job = **one topic**, which keeps a run inside the queue's
`job_timeout_minutes` (180) and gives every topic its own log, its own retry and
its own result file. Do not batch ten topics into one job; one bad topic then
takes the whole run down with it.

- Driver: `C:\AI-Server\scripts\research_qwen.py` (topics are a dict at the top)
- Handler: `C:\AI-Server\scripts\jobkinds\qwenresearch.ps1`
- Output: `C:\AI-Server\out\llm-efficiency\<id>-<slug>.md`, plus a
  `.notes.md` with the raw notes and the citation check, plus a Discord post
- Log: `C:\AI-Server\logs\jobs\<job-id>-qwenresearch.log`

## A topic is a pipeline, not a prompt

One turn produces a survey, not research. Depth needs the model to plan, read,
check itself, then write:

```
SURVEY   map the field -> 3 clusters, each naming specific papers to read
  |
DIVE x3  one fresh session per cluster: fetch the actual sources, take notes
  |
VERIFY   re-check every arXiv id the notes cite really resolves, and that the
         title matches what was claimed -> a correction list
  |
SYNTH    write the final report from the notes plus the corrections
```

Budget roughly 45-90 min per topic. That is the price of depth and the reason
this belongs on the queue.

**Every phase gets a FRESH session, carrying forward only the distilled notes.**
This is the load-bearing decision. The agent keeps full history per session and
a single `web_fetch` returns up to 20k characters, so a six-turn conversation
buries the model in raw HTML long before the last turn. Pass notes, never
transcripts.

`QWEN_TURN_TIME_BUDGET_SEC` caps ONE phase, not the job, and it is read when
`config` is imported — set it in the environment before importing `agent`, or it
silently keeps the default.

**The VERIFY phase is not optional, and it earns its keep.** On its first real
run it caught `2412.19437` cited as the auxiliary-loss-free load-balancing paper
when it is actually the DeepSeek-V3 Technical Report -- a wrong citation that
would have read as authoritative. A 27B model produces fluent, plausible, wrong
arXiv ids, and a survey full of them looks exactly like a good one.

Exclude your own structural headings from the citation extractor. Feeding it
`### Cluster 1 notes` as a "claimed title" makes VERIFY report a false WRONG,
which buries the real ones.

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

## The synthesis phase will narrate its plan unless you stop it

Observed 2026-08-31 on topic 03: the SYNTH phase spent its entire token budget
writing *"Let me carefully organize this review... Entry list (targeting 4-8)..."*
and never produced a document. 234 lines, zero `##` headings. The job exited 0
and archived a plan as if it were a review.

Three things fix it, and you want all three:

1. **Do not ask one phase to decide and write.** The old prompt asked the model
   to apply citation corrections AND merge duplicates AND write the report,
   which is an invitation to think out loud. Tell it the research is done and it
   is only writing; say "apply corrections silently".
2. **Pin the first line.** "Your very first line must be exactly `## <topic>`.
   Any other first line is a failed response." Then strip anything before the
   first `##` anyway (`clean_report`) -- it sometimes narrates regardless.
3. **Validate structure and exit non-zero.** `looks_like_a_report` requires a
   `##` heading, 3+ `###` entries and 1500+ characters. Without that check a
   plan-shaped failure looks exactly like success to the queue, which is
   AGENTS.md rule 5 in its purest form: the return path said 0, the effect was
   a wasted hour.

The bad output is saved as `<id>-<slug>.FAILED.md` so the retry can be compared
against it.

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
