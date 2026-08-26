# Skills

Drop these into an agent harness so it gains a capability *with the guardrails
attached* — the rules and the commands arrive together, instead of an agent
learning the commands and rediscovering the rules the expensive way.

| Skill | Covers |
|---|---|
| `ai-server-jobs` | submitting, scheduling and watching work on the queue |
| `ai-server-gpu` | reserving a GPU so concurrent jobs do not collide |
| `ai-server-wake` | waking the box, and diagnosing why it will or will not sleep |

## Installing

Claude Code — copy into a project (or `~/.claude/skills/` for every project):

```bash
cp -r skills/ai-server-jobs  /path/to/project/.claude/skills/
cp -r skills/ai-server-gpu   /path/to/project/.claude/skills/
cp -r skills/ai-server-wake  /path/to/project/.claude/skills/
```

Other harnesses: each `SKILL.md` is plain Markdown with YAML frontmatter
(`name`, `description`). The description is what a model matches against when
deciding whether the skill applies, so keep it phrased in the user's words
("upscale this", "the server is down") rather than in implementation terms.

## Also worth loading

[`AGENTS.md`](../AGENTS.md) at the repo root is the short version of everything
an agent must not do here. It is worth pasting into a system prompt for any
agent that will touch this machine unattended.
