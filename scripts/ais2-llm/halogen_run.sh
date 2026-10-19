#!/bin/sh
# test run of halogen-flash-server 0.18.11 on the huihui abliterated UD-Q4_K_XL GGUF (same weights as gufo), port $PORT
PORT=${PORT:-8731}
M=/srv/llm/models
exec sudo -n podman run -d --name halogen-bench --replace \
  -p $PORT:$PORT -e HALOGEN_API_PORT=$PORT \
  --device /dev/kfd --device /dev/dri --group-add 991 --group-add 44 \
  --ipc=host --ulimit memlock=-1:-1 --cpuset-cpus=${CPUS:-14,15,30,31} --oom-score-adj=-900 \
  -v $M:/models:ro -v /home/taiwong/.config/ai-server-2/llm_api_key:/run/llm_key:ro \
  -e HALOGEN_API_KEY_FILE=/run/llm_key \
  -e HALOGEN_CHECKPOINT=/models/huihui-ai/Huihui-Qwen3.8-Flash-Next-abliterated-GGUF/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  -e HALOGEN_MTP_HEAD=/models/peonist-ai/halogen-qwen3.8-flash-next/qwen38-flash-next-mtp.hgn \
  -e HALOGEN_TOKENIZER=/models/peonist-ai/halogen-qwen3.8-flash-next/tokenizer \
  -e HALOGEN_MODEL_ID=qwen3.8-flash-next-uncensored \
  -e HALOGEN_KV_SLOTS=${SLOTS:-2} -e HALOGEN_CTX=${CTX:-262144} ${POOL:+-e HALOGEN_KV_POOL_POSITIONS=$POOL} \
  ${RESERVE:+-e HALOGEN_HOST_RESERVE_GIB=$RESERVE} ${MAXTOK:+-e HALOGEN_MAX_TOK=$MAXTOK} ${EXTRA} \
  ghcr.io/peonist-ai/halogen-flash-server@sha256:a5797467d2bff173e0c661d9700292bd55eac305faff68c86261ae35385ad6ad
