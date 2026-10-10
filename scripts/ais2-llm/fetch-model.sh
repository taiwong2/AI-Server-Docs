#!/bin/bash
# Resumable, checksum-verified fetch of the abliterated Flash-Next UD-Q4_K_XL + shared-Q8 MTP head.
# Writes $MARK only when every file matches its Hugging Face LFS sha256; llm-gufo.service requires $MARK.
set -u
D=/srv/llm/models
MARK=$D/.verified-qwen38-flash-next-abliterated
H=https://huggingface.co/huihui-ai/Huihui-Qwen3.8-Flash-Next-abliterated-GGUF/resolve/main
U=https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main
HP=huihui-ai/Huihui-Qwen3.8-Flash-Next-abliterated-GGUF/UD-Q4_K_XL
# path|url|size|sha256
FILES="
$HP/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|$H/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|10946752|290a31ca20b74ed2c21b257d378a5678d821ad9fdd8feb1fc52c719761668903
$HP/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|$H/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|49859583296|0ebf70d076e0e98f74dc414a90b92c67d7267876ae524bc7799cf463e27b754b
$HP/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|$H/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|49376141664|e9b12f44e13e60d6ef9396449f7b4356b2e2911222b8183a596830c2418db19a
$HP/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|$H/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|12087983680|983901b3e47686f56f5fcec87ba8c51e7e2c6996277dd77bc3fc804a1d563da3
unsloth/Qwen3.8-Flash-Next-GGUF/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|$U/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|2786568256|5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6
"
[ -f "$MARK" ] && { echo "already verified"; exit 0; }
fetch() { # path url size
  local f=$D/$1 sz
  mkdir -p "$(dirname "$f")"
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$3" ]; then echo "oversize $f, deleting"; rm -f "$f"; sz=0; fi
  if [ "$sz" -lt "$3" ] && [ "$sz" -gt 268435456 ]; then
    # drop the last 256 MiB before resuming, in case the tail was not flushed before a power cut
    truncate -s $((sz - 268435456)) "$f"
  fi
  while [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -lt "$3" ]; do
    curl -fsSL --retry 20 --retry-delay 5 --retry-all-errors -C - -o "$f" "$2" || { echo "curl rc=$? $f, retrying"; sleep 10; }
  done
  echo "fetched $f"
}
# loop in the current shell (here-string, not a pipe) so `wait` really waits for every fetch
while IFS="|" read -r p u s h; do [ -n "$p" ] && fetch "$p" "$u" "$s" & done <<< "$FILES"
wait
for_sz_ok=1
while IFS="|" read -r p u s h; do [ -z "$p" ] && continue; [ "$(stat -c %s "$D/$p" 2>/dev/null || echo 0)" = "$s" ] || { echo "size mismatch $p"; for_sz_ok=0; }; done <<< "$FILES"
[ $for_sz_ok = 1 ] || exit 1
ok=1
while IFS="|" read -r p u s h; do
  [ -z "$p" ] && continue
  got=$(sha256sum "$D/$p" | cut -d" " -f1)
  if [ "$got" = "$h" ]; then echo "OK  $p"; else echo "BAD $p ($got) -> deleting for re-download"; rm -f "$D/$p"; ok=0; fi
done <<< "$FILES"
[ $ok = 1 ] || exit 1
date -Is > "$MARK"; echo "ALL VERIFIED"
