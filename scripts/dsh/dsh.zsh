#!/bin/zsh
set -euo pipefail
# The install root is this script's directory's parent (symlinks resolved: ~/.local/bin/dsh -> <root>/bin/dsh).
ROOT=${DSH_ROOT:-${0:A:h:h}}
export DSH_HOME="${DSH_HOME:-$ROOT/home}"
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-workspace-write}"
DSH_BIN="$ROOT/node_modules/.bin/dsh"
HOOK="$ROOT/bin/dsh-llm-mode"

# Make headless—the normal one-shot agent profile—the default, while preserving
# explicit profile selection and the top-level launcher commands.
case "${1:-}" in
  --help|-h|--version|-V|plugin) exec "$DSH_BIN" "$@" ;;
  "") ARGS=(--profile web) ;;   # bare `dsh` = the interactive browser UI, through LLM mode
  web|--profile) ARGS=("$@") ;;
  *) ARGS=(--profile headless "$@") ;;
esac

# LLM mode (2026-10-11): typed in a terminal, dsh first turns on AI Server 2's LLM mode (its Clash jobs move off, the
# Flash-Next model loads) and keeps it alive while the session runs; the box unloads after 30 min with no session and
# no requests. Scripts / agents (no TTY) and DSH_NO_LLM_MODE=1 keep the old behaviour: the proxy (127.0.0.1:1235)
# routes every model to AI Server 2 (AI Server 1 serves no LLM since 2026-10-12).
if [[ -t 0 && -t 1 && -z "${DSH_NO_LLM_MODE:-}" && -x "$HOOK" ]]; then
  "$HOOK" on || true
  ( while sleep 300; do "$HOOK" touch; done ) &!
  KEEP=$!
  set +e
  "$DSH_BIN" "${ARGS[@]}"
  rc=$?
  kill $KEEP 2>/dev/null
  ( "$HOOK" touch & ) >/dev/null 2>&1
  exit $rc
fi
exec "$DSH_BIN" "${ARGS[@]}"
