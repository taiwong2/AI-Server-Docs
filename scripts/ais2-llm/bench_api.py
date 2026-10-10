#!/usr/bin/env python3
"""Benchmark the LLM API: bench_api.py CTX [MAX_TOKENS] [CONC] [kind]
CTX = approx prompt tokens of random filler (unique nonce per request, so no cache hits).
kind: prose|code. Prints gufo-reported prefill/decode rates, TTFT and MTP acceptance.
Key: $LLM_API_KEY or /etc/ai-server-2/llm.env. URL: $LLM_URL."""
import json, os, sys, time, urllib.request, random, threading

URL = os.environ.get("LLM_URL", "http://127.0.0.1:8080/v1/chat/completions")
MODEL = os.environ.get("LLM_MODEL", "qwen3.8-flash-next-uncensored")
key = os.environ.get("LLM_API_KEY")
if not key:
    for l in open("/etc/ai-server-2/llm.env"):
        if l.startswith("LLM_API_KEY="):
            key = l.strip().split("=", 1)[1]
ctx = int(sys.argv[1])
ntok = int(sys.argv[2]) if len(sys.argv) > 2 else 256
conc = int(sys.argv[3]) if len(sys.argv) > 3 else 1
kind = sys.argv[4] if len(sys.argv) > 4 else "prose"
WORDS = ("the river ancient market silver engine quiet harbor lantern copper winter garden signal orbit "
         "marble thunder paper falcon velvet canyon meadow crystal pilot ember forest saddle violet anchor "
         "glacier prism hollow rocket lemon spiral tunnel willow badge cobalt drift fable granite").split()
TASK = {
    "prose": "Ignore the text above. Write a detailed, multi-paragraph explanation of how a refrigerator works.",
    "code": "Ignore the text above. Write a complete Python module implementing a thread-safe LRU cache "
            "with TTL expiry, with docstrings and unit tests.",
}[kind]


def one(i, out):
    rnd = random.Random(time.time_ns() + i)
    filler = ""
    if ctx > 64:
        filler = "[nonce %d %d]\n" % (time.time_ns(), i) + " ".join(
            rnd.choice(WORDS) for _ in range(int(ctx / 1.2))) + "\n\n"
    body = {"model": MODEL, "max_tokens": ntok, "temperature": 0, "reasoning_effort": "none",
            "messages": [{"role": "user", "content": filler + TASK}]}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    t0 = time.time()
    d = json.load(urllib.request.urlopen(req, timeout=7200))
    u = d["usage"]
    g = u.get("gufo", {})
    out[i] = {"prompt_tokens": u["prompt_tokens"], "completion_tokens": u["completion_tokens"],
              "pp_tok_s": round(u.get("prompt_tokens_per_second", 0), 1),
              "tg_tok_s": round(u.get("completion_tokens_per_second", 0), 2),
              "ttft_s": round(g.get("ttft_ms", 0) / 1000, 2), "wall_s": round(time.time() - t0, 1),
              "mtp_accept": "%s/%s" % (u.get("draft_tokens_accepted"), u.get("draft_tokens")),
              "plan": g.get("execution_plan")}


out = {}
th = [threading.Thread(target=one, args=(i, out)) for i in range(conc)]
[t.start() for t in th]
[t.join() for t in th]
la = open("/proc/loadavg").read().split()[0]
for i in sorted(out):
    print(json.dumps({"ctx": ctx, "conc": conc, "kind": kind, "load1": la, **out[i]}), flush=True)
if conc > 1:
    print(json.dumps({"ctx": ctx, "conc": conc, "aggregate_tg_tok_s": round(sum(o["tg_tok_s"] for o in out.values()), 1)}))
