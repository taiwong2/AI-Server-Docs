#!/bin/bash
# Test double for `claude -p` (aq test.sh). The first call per session fails with a usage limit that resets in
# FAKE_RESET_IN seconds (written both as text and as a transcript record with quotaLimits.resetsAt); later calls
# succeed. Every call's argv is appended to $FAKE_DIR/calls.log.
set -u
mkdir -p "$FAKE_DIR"
printf '%s\n' "$(date -u +%FT%TZ) $*" >> "$FAKE_DIR/calls.log"
sid=""; prev=""
for a in "$@"; do
  if [[ "$prev" == "--session-id" || "$prev" == "--resume" ]]; then sid="$a"; fi
  prev="$a"
done
n=$(cat "$FAKE_DIR/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$FAKE_DIR/count"
if [[ $n -eq 1 ]]; then
  reset=$(( $(date +%s) + ${FAKE_RESET_IN:-40} ))
  hhmm=$(date -r $reset +%-I:%M%p | tr 'A-Z' 'a-z')
  mkdir -p "$AQ_PROJECTS/-fake"
  printf '{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"timestamp":"%s","quotaLimits":{"status":"rejected","resetsAt":%d},"sessionId":"%s","message":{"role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets %s (America/Chicago)"}]}}\n' \
    "$(date -u +%FT%T.000Z)" $reset "$sid" "$hhmm" >> "$AQ_PROJECTS/-fake/$sid.jsonl"
  printf '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit · resets %s (America/Chicago)","session_id":"%s"}\n' "$hhmm" "$sid"
  exit 1
fi
printf '{"type":"result","subtype":"success","is_error":false,"result":"FAKE-OK call %d","session_id":"%s"}\n' $n "$sid"
