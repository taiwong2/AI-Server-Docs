#!/bin/bash
# End-to-end test of aq with a fake claude: a task hits a usage limit, the runner marks it pending, waits for the
# reset without calling claude again, then resumes the same session and finishes. Uses a throwaway AQ_HOME.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/aqtest.XXXX")
export AQ_HOME=$T/q AQ_PROJECTS=$T/projects AQ_CLAUDE_BIN=$HERE/fake_claude.sh FAKE_DIR=$T/fake
export AQ_POLL=2 AQ_RESET_SLACK=3 AQ_SWEEP_EVERY=100000 FAKE_RESET_IN=${FAKE_RESET_IN:-25}
AQ="/usr/bin/python3 $HERE/aq"
id=$($AQ add --label t1 --cwd "$T" "say hello")
t0=$(date +%s)
AQ_ONCE=1 AQ_VERBOSE=1 $AQ run
t1=$(date +%s)
$AQ show "$id" | sed -n '1,40p'
echo "--- calls"; cat "$FAKE_DIR/calls.log" | cut -c1-200
calls=$(wc -l < "$FAKE_DIR/calls.log")
st=$($AQ show "$id" --json | /usr/bin/python3 -c 'import json,sys; t=json.load(sys.stdin); print(t["status"], t["limit_hits"], t["attempts"])')
echo "status/limit_hits/attempts: $st  calls=$calls  waited=$((t1-t0))s"
[[ "$st" == "done 1 0" && $calls -eq 2 && $((t1-t0)) -ge $((FAKE_RESET_IN)) ]] || { echo FAIL; exit 1; }
grep -q -- "--resume" <(sed -n 2p "$FAKE_DIR/calls.log") || { echo "FAIL: 2nd call did not --resume"; exit 1; }
echo "PASS 1: usage limit -> wait for reset -> resume same session"

# 2. hook + sweeper + dsh fallback while blocked (fake dsh, fake transcripts)
export AQ_HOME=$T/q2 AQ_DSH_BIN=$T/fake_dsh.sh
printf '#!/bin/bash\necho "FAKE-DSH ran in $PWD keep=$DSH_KEEP_CWD nollm=$DSH_NO_LLM_MODE"\n' > "$AQ_DSH_BIN"; chmod +x "$AQ_DSH_BIN"
SID=11111111-2222-3333-4444-555555555555
mk() {  # mk AGENT_ID -> a subagent transcript that ends in a usage-limit error
  mkdir -p "$AQ_PROJECTS/-proj/$SID/subagents"
  printf '{"type":"assistant","sessionId":"%s","cwd":"%s","timestamp":"%s","message":{"content":[{"type":"text","text":"working"}]}}\n{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"sessionId":"%s","cwd":"%s","timestamp":"%s","quotaLimits":{"resetsAt":%d},"message":{"content":[{"type":"text","text":"You have hit your session limit · resets 9:20pm (America/Chicago)"}]}}\n' \
    $SID "$T" "$(date -u +%FT%T.000Z)" $SID "$T" "$(date -u +%FT%T.000Z)" $(( $(date +%s) + 3600 )) > "$AQ_PROJECTS/-proj/$SID/subagents/agent-$1.jsonl"
}
$AQ sweep                     # first sweep only arms sweep_since
sleep 1; mk aaaahook1
echo '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"'$SID'","agent_id":"aaaahook1","cwd":"'$T'","last_assistant_message":"You have hit your session limit · resets 9:20pm (America/Chicago)"}' | $AQ hook
mk bbbbsweep2; $AQ sweep
fb=$($AQ add --fallback dsh --label fbtest "check something")
$AQ list
n=$($AQ list | grep -cE 'resume-(aaaahook1|bbbbsweep2)')
$AQ status | grep -q '"blocked": true' || { echo "FAIL: not blocked"; exit 1; }
[[ $n -eq 2 ]] || { echo "FAIL: expected 2 resume tasks, got $n"; exit 1; }
$AQ show resume-aaaahook1 | grep -q "aq notes --session $SID --agent aaaahook1" || { echo FAIL prompt; exit 1; }
# run one tick-ish: the fallback task must run on dsh while claude stays blocked; resume tasks wait
( AQ_VERBOSE=1 $AQ run & echo $! > $T/rpid; wait ) & sleep 8; kill $(cat $T/rpid) 2>/dev/null || true; sleep 1
$AQ show "$fb" | grep -E '^(status|ran_on)'
$AQ show "$fb" | grep -q 'ran_on            dsh' || { echo "FAIL: fallback did not run on dsh"; exit 1; }
$AQ log "$fb" | grep -q 'FAKE-DSH ran in .*keep=1 nollm=1' || { echo "FAIL: dsh env"; exit 1; }
[[ $($AQ list | grep -E 'resume-' | grep -c pending) -eq 2 ]] || { echo "FAIL: resume tasks should still wait"; exit 1; }
echo "PASS 2: hook + sweeper queue resumes, block set, fallback=dsh runs during the outage"
rm -rf "$T"
