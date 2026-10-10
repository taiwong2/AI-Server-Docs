#!/bin/sh
# ExecStartPre for llm-gufo: the model + 262k KV take ~91 GiB of GTT; load only with >= NEED GiB available
# so the load cannot OOM-kill running battle/training jobs (it retries via Restart=always until memory frees).
NEED=${LLM_NEED_GIB:-104}
AVAIL=$(awk "/MemAvailable/{print int(\$2/1048576)}" /proc/meminfo)
if [ "$AVAIL" -lt "$NEED" ]; then echo "llm-gufo: MemAvailable ${AVAIL} GiB < ${NEED} GiB, not loading (stop battle jobs or lower context)"; exit 1; fi
echo "llm-gufo: MemAvailable ${AVAIL} GiB, loading"
