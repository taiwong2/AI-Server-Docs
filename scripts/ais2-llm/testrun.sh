#!/bin/bash
# testrun.sh "<extra llm flags>" ["<server flags>"]: run a temporary gufo on :8080 (llm-gufo must be stopped).
# The model takes ~86-91 GiB: never while clashjobs has running jobs (2026-10-10 a test load OOM-killed a training run).
if clashjobs list 2>/dev/null | grep -q " running "; then echo "refusing: clashjobs has running jobs" >&2; exit 1; fi
sudo podman rm -f -t 60 llm-test >/dev/null 2>&1
sudo podman run -d --name llm-test --network host --device /dev/kfd --device /dev/dri --group-add 991 --group-add 44 \
  --ulimit memlock=-1:-1 -v /srv/llm/models:/models:ro --env-file /etc/ai-server-2/llm.env --cpuset-cpus=14,15,30,31 --oom-score-adj=-900 \
  ghcr.io/gufo-org/toolboxes/gufo-runtime:0.10.0 sh -c "exec gufo serve --host 0.0.0.0 --port 8080 $2 --api-key \"\$LLM_API_KEY\" llm \
  --model /models/huihui-ai/Huihui-Qwen3.8-Flash-Next-abliterated-GGUF/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --served-model-name qwen3.8-flash-next-uncensored --cache-ram-bytes 4294967296 $1" >/dev/null
timeout 180 bash -c "until sudo podman logs llm-test 2>&1 | grep -qE \"event=listening|load_failed|Error\"; do sleep 3; done"
sudo podman logs llm-test 2>&1 | grep -oE "load_completed.*|Error.*" | head -2
