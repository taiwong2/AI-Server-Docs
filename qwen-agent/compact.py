"""Context compaction for the qwen agent — the piece it never had.

Sessions here grow without bound: every tool result is appended verbatim and
nothing ever trims. Measured 2026-08-31, a single research dive reached 760 KB
(~211k tokens) in one turn, well past what the model can actually attend to, and
a long-lived Discord channel walks the same path more slowly.

The fix is ELISION, not summarization:

- Tool results are ~95% of the bulk (a `web_fetch` returns up to 150 KB) and are
  the least useful thing to keep verbatim once the model has read them and moved
  on. Their content is replaced with a head plus a marker.
- The message is KEPT, with its `tool_call_id`. Deleting a tool message whose
  assistant `tool_call` still exists produces an invalid conversation that the
  API rejects — that is the trap this function exists to avoid.
- The system prompt, the first user message (the actual task) and the most
  recent exchanges survive untouched, so the model keeps its instructions and
  its immediate working state.

No model call, no cost, deterministic, and reversible in the sense that the
on-disk session keeps whatever was saved before compaction ran.
"""

import json

# Trigger well below the point where quality degrades, in characters (~3.6
# chars/token for this tokenizer). 200k chars is roughly 55k tokens.
TRIGGER_CHARS = 200_000
# Messages at the tail that are never touched. Deliberately small: a research
# dive makes FEW but ENORMOUS tool calls (a single web_fetch can return 150 KB),
# so a large protected tail shields almost all of the bulk and compaction does
# nothing. Four keeps the immediate working set and no more.
KEEP_RECENT = 4
# No single tool result is worth this much context, wherever it sits. The most
# recent one is exempt -- the model is actively working with it.
HARD_CAP = 45_000
# How much of an elided tool result to keep.
TOOL_HEAD = 700
# Stop eliding once we are under this.
TARGET_CHARS = 120_000

ELIDED = "\n\n[... {n:,} more characters elided to fit the context window ...]"


def message_chars(m):
    n = len(str(m.get("content") or ""))
    if m.get("tool_calls"):
        try:
            n += len(json.dumps(m["tool_calls"]))
        except Exception:
            n += 200
    return n


def session_chars(messages):
    return sum(message_chars(m) for m in messages)


def compact(messages, trigger=TRIGGER_CHARS, keep_recent=KEEP_RECENT,
            tool_head=TOOL_HEAD, target=TARGET_CHARS, hard_cap=HARD_CAP):
    """Return (messages, chars_saved). Non-mutating; safe to call every turn."""
    total = session_chars(messages)
    if total <= trigger or len(messages) <= keep_recent + 2:
        return messages, 0

    out = [dict(m) for m in messages]
    saved_cap = 0

    # First: cap any oversized tool result anywhere except the newest one. A
    # 150 KB page dump exceeds what the model can use from a single result even
    # when it is recent, so this is a quality fix as much as a context one.
    last_tool = max((i for i, m in enumerate(out) if m.get("role") == "tool"), default=-1)
    for i, m in enumerate(out):
        if i == last_tool or m.get("role") != "tool":
            continue
        content = str(m.get("content") or "")
        if len(content) > hard_cap:
            cut = len(content) - hard_cap
            m["content"] = content[:hard_cap] + ELIDED.format(n=cut)
            saved_cap += cut
    # Never touch: index 0 (system), index 1 (the task), and the tail.
    first = 2
    last = len(out) - keep_recent
    saved = saved_cap

    # Oldest first: the further back a tool result is, the less it is needed.
    for i in range(first, max(first, last)):
        if total - saved <= target:
            break
        m = out[i]
        if m.get("role") != "tool":
            continue
        content = str(m.get("content") or "")
        if len(content) <= tool_head + 120:
            continue
        cut = len(content) - tool_head
        m["content"] = content[:tool_head] + ELIDED.format(n=cut)
        saved += cut

    # Still oversized: elide long assistant prose too, keeping any tool_calls
    # intact so the conversation structure survives.
    if total - saved > target:
        for i in range(first, max(first, last)):
            if total - saved <= target:
                break
            m = out[i]
            if m.get("role") != "assistant":
                continue
            content = str(m.get("content") or "")
            if len(content) <= tool_head + 120:
                continue
            cut = len(content) - tool_head
            m["content"] = content[:tool_head] + ELIDED.format(n=cut)
            saved += cut

    return out, saved


def _valid(messages):
    """Every assistant tool_call id must still have a matching tool message."""
    want, have = set(), set()
    for m in messages:
        for c in (m.get("tool_calls") or []):
            if c.get("id"):
                want.add(c["id"])
        if m.get("role") == "tool" and m.get("tool_call_id"):
            have.add(m["tool_call_id"])
    return want <= have, want - have


if __name__ == "__main__":
    # Build a session shaped like a real research dive.
    msgs = [{"role": "system", "content": "sys"}, {"role": "user", "content": "research X"}]
    for i in range(40):
        msgs.append({"role": "assistant", "content": "thinking " * 50,
                     "tool_calls": [{"id": f"c{i}", "function": {"name": "web_fetch",
                                                                 "arguments": "{}"}}]})
        msgs.append({"role": "tool", "tool_call_id": f"c{i}", "content": "X" * 20000})
    msgs.append({"role": "assistant", "content": "final"})

    before = session_chars(msgs)
    ok0, _ = _valid(msgs)
    new, saved = compact(msgs)
    after = session_chars(new)
    ok1, missing = _valid(new)

    print("before      : %10s chars (~%s tok)" % (f"{before:,}", f"{int(before/3.6):,}"))
    print("after       : %10s chars (~%s tok)" % (f"{after:,}", f"{int(after/3.6):,}"))
    print("saved       : %10s chars (%.0f%%)" % (f"{saved:,}", 100.0 * saved / before))
    print("valid before: %s   valid after: %s  (missing: %s)" % (ok0, ok1, missing or "none"))
    print("system kept : %r" % new[0]["content"])
    print("task kept   : %r" % new[1]["content"])
    print("tail intact : %r" % new[-1]["content"])
    print("msg count   : %d -> %d (never drops messages)" % (len(msgs), len(new)))
    n_elided = sum(1 for m in new if "elided to fit" in str(m.get("content") or ""))
    print("elided msgs : %d" % n_elided)
    small = [{"role": "system", "content": "s"}, {"role": "user", "content": "hi"}]
    print("no-op on small session:", compact(small)[1] == 0)
    # idempotent
    again, saved2 = compact(new)
    print("second pass saves      :", saved2)
