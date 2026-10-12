#!/bin/bash
# Install / update the agent queue on this Mac: aq -> ~/.claude/agent-queue/bin (+ ~/.local/bin/aq), the runner
# LaunchAgent, and the Claude Code StopFailure hook (matcher rate_limit) in ~/.claude/settings.json.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
Q=~/.claude/agent-queue
mkdir -p $Q/bin ~/.local/bin
install -m 755 "$HERE/aq" $Q/bin/aq
ln -sf $Q/bin/aq ~/.local/bin/aq
/usr/bin/python3 - <<'PY'
import json, os, shutil, time
p = os.path.expanduser("~/.claude/settings.json")
shutil.copy(p, p + ".bak-aq-%d" % int(time.time()))
s = json.load(open(p))
cmd = "/usr/bin/python3 %s/.claude/agent-queue/bin/aq hook" % os.path.expanduser("~")
ent = s.setdefault("hooks", {}).setdefault("StopFailure", [])
if not any(h.get("command") == cmd for e in ent for h in e.get("hooks", [])):
    ent.append({"matcher": "rate_limit", "hooks": [{"type": "command", "command": cmd, "timeout": 30}]})
    json.dump(s, open(p + ".tmp", "w"), indent=2); os.replace(p + ".tmp", p)
    print("hook added")
else:
    print("hook present")
PY
P=~/Library/LaunchAgents/com.taiwong.agent-queue.plist
cp "$HERE/com.taiwong.agent-queue.plist" $P
launchctl bootout gui/$(id -u)/com.taiwong.agent-queue 2>/dev/null || true
for i in 1 2 3 4 5; do sleep 2; launchctl bootstrap gui/$(id -u) $P 2>/dev/null && break; done  # bootout is async
sleep 2; ~/.local/bin/aq list | head -3
