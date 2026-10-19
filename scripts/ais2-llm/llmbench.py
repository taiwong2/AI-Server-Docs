#!/usr/bin/env python3
"""gufo vs halogen benchmark (stdlib only). Usage: llmbench.py URL KEYFILE LABEL OUT.jsonl [tests...]
tests: calib cold32 cold190 decode trace conc2 facts maxctx:N"""
import json, os, random, sys, threading, time, urllib.request
from pathlib import Path

URL, KEYF, LABEL, OUT = sys.argv[1:5]
TESTS = sys.argv[5:] or ["calib", "facts", "decode", "cold32", "conc2", "cold190", "trace"]
KEY = Path(KEYF).read_text().strip()
MODEL = "qwen3.8-flash-next-uncensored"
CPT = float(os.environ.get("CPT", "3.3"))          # chars per token, refined by calib

files = sorted(p for d in ["ops", "clashlab", "tools", "agent", "docs"]
               for p in (Path.home() / "ClashEngineering" / d).rglob("*") if p.suffix in (".py", ".md") and p.is_file())
CORPUS = "\n".join(f"### FILE {p.name}\n" + p.read_text(errors="ignore") for p in files)
while len(CORPUS) < 6_000_000:
    CORPUS += CORPUS


def doc(ntok, off=0, needle=None):
    n = int(ntok * CPT)
    s = CORPUS[off:off + n]
    if needle:
        m = len(s) // 2
        s = s[:m] + "\n" + needle + "\n" + s[m:]
    return s


def log(rec):
    rec.update(engine=LABEL, ts=time.strftime("%H:%M:%S"))
    print(json.dumps(rec), flush=True)
    with open(OUT, "a") as fh:
        fh.write(json.dumps(rec) + "\n")


def call(messages, max_tokens=128, think=False, timeout=3600):
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens, "stream": True,
            "stream_options": {"include_usage": True}, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": think}}
    req = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    t0 = time.time(); ttft = None; content = ""; reasoning = ""; usage = {}; timings = {}; ntok_stream = 0; fin = None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for raw in r:
                line = raw.decode(errors="ignore").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    ev = json.loads(data)
                except ValueError:
                    continue
                if ev.get("usage"):
                    usage = ev["usage"]
                if ev.get("timings"):
                    timings = ev["timings"]
                for ch in ev.get("choices") or []:
                    d = ch.get("delta") or {}
                    piece = (d.get("content") or "") + (d.get("reasoning_content") or d.get("reasoning") or "")
                    if piece:
                        if ttft is None:
                            ttft = time.time() - t0
                        ntok_stream += 1
                    content += d.get("content") or ""
                    reasoning += d.get("reasoning_content") or d.get("reasoning") or ""
                    fin = ch.get("finish_reason") or fin
    except Exception as e:                                                   # noqa: BLE001
        return {"error": repr(e)[:300], "wall": round(time.time() - t0, 2)}
    wall = time.time() - t0
    ct = usage.get("completion_tokens") or ntok_stream
    dec = (ct - 1) / (wall - ttft) if ttft and ct > 1 and wall > ttft else None
    det = usage.get("prompt_tokens_details") or {}
    return {"wall": round(wall, 2), "ttft": round(ttft, 2) if ttft else None, "prompt_tokens": usage.get("prompt_tokens"),
            "cached_tokens": det.get("cached_tokens"), "completion_tokens": ct,
            "decode_tps": round(dec, 1) if dec else None, "finish": fin, "content": content[:200],
            "reasoning_chars": len(reasoning), "timings": timings}


def nonce():
    return f"[session {random.randrange(10**12)}] "


SYS = {"role": "system", "content": "You are a careful coding assistant. Answer briefly."}

for t in TESTS:
    if t == "calib":
        r = call([SYS, {"role": "user", "content": nonce() + doc(5000) + "\nReply with OK."}], 8)
        if r.get("prompt_tokens"):
            CPT = int(5000 * CPT) / (r["prompt_tokens"] - 40)
        log({"test": "calib", "cpt": round(CPT, 3), **r})
    elif t == "facts":
        for q, want in [("What is 17*23? Answer with the number only.", "391"),
                        ("What is the capital of Australia? One word.", "Canberra"),
                        ("Reverse the string 'halogen'. Output only the result.", "negolah"),
                        ("Write a Python one-liner that sums the squares of 1..10 and the value it prints. Value only.", "385")]:
            r = call([SYS, {"role": "user", "content": q}], 64)
            log({"test": "facts", "q": q, "ok": want.lower() in (r.get("content") or "").lower(), **r})
    elif t == "decode":
        r = call([SYS, {"role": "user", "content": "Write a 700-word story about a lighthouse keeper. No preamble."}], 700)
        log({"test": "decode_short", **r})
        r = call([SYS, {"role": "user", "content": "Write a Python implementation of a red-black tree with insert and delete, with comments."}], 700)
        log({"test": "decode_code", **r})
    elif t.startswith("cold"):
        n = int(t[4:]) * 1000
        needle = f"The deployment passphrase is MAGENTA-OTTER-{random.randrange(1000, 9999)}."
        msgs = [SYS, {"role": "user", "content": nonce() + doc(n, random.randrange(10**6), needle)
                      + "\n\nQuestion: what is the deployment passphrase mentioned above? Answer with the passphrase only."}]
        r = call(msgs, 64)
        log({"test": f"cold{t[4:]}k", "needle_ok": needle.split()[-1].rstrip(".") in (r.get("content") or ""), **r})
        msgs += [{"role": "assistant", "content": r.get("content") or "ok"},
                 {"role": "user", "content": "Which FILE header appears first in the document? Name only."}]
        r = call(msgs, 64)
        log({"test": f"warm{t[4:]}k", **r})
        msgs += [{"role": "assistant", "content": r.get("content") or "ok"},
                 {"role": "user", "content": "Explain in about 200 words what the code in the document does overall."}]
        r = call(msgs, 300)
        log({"test": f"decode_at_{t[4:]}k", **r})
    elif t == "trace":
        # dsh-like: big growing prefix, each turn appends assistant reply + ~2k-token tool output
        base = int(os.environ.get("TRACE_K", "180")) * 1000
        off = random.randrange(10**6)
        msgs = [SYS, {"role": "user", "content": nonce() + doc(base, off) + "\n\nRead the repository above. Reply 'ready'."}]
        for i in range(int(os.environ.get("TRACE_TURNS", "6"))):
            r = call(msgs, 128)
            log({"test": "trace", "turn": i, **r})
            if os.environ.get("TRACE_INTERFERE"):
                # another client between turns (dsh subagent / AS1 relay / Discord bot): a short unrelated chat
                ri = call([{"role": "system", "content": "You are a terse helper."},
                           {"role": "user", "content": nonce() + doc(3000, random.randrange(10**6)) + "\nOne word: language of this code?"}], 16)
                log({"test": "interfere", "turn": i, **ri})
            off += int(2000 * CPT) * 3
            msgs += [{"role": "assistant", "content": r.get("content") or "ok"},
                     {"role": "user", "content": "Tool output (cat):\n" + doc(2000, off) + "\n\nIn one sentence, what does this file do?"}]
    elif t == "conc2":
        res = {}
        def worker(k, msgs):
            res[k] = call(msgs, 128)
        convs = {k: [SYS, {"role": "user", "content": nonce() + doc(32000, random.randrange(10**6)) + "\nSummarise in 2 sentences."}]
                 for k in ("a", "b")}
        for phase in ("cold", "warm"):
            t0 = time.time()
            th = [threading.Thread(target=worker, args=(k, m)) for k, m in convs.items()]
            [x.start() for x in th]; [x.join() for x in th]
            log({"test": f"conc2_{phase}", "wall_both": round(time.time() - t0, 2),
                 "empty": [k for k in res if not (res[k].get("content") or "").strip()], "a": res["a"], "b": res["b"]})
            for k in convs:
                convs[k] += [{"role": "assistant", "content": res[k].get("content") or "ok"},
                             {"role": "user", "content": "Now name three functions defined in it."}]
    elif t.startswith("maxctx:"):
        n = int(t.split(":")[1])
        needle = f"The deployment passphrase is MAGENTA-OTTER-{random.randrange(1000, 9999)}."
        r = call([SYS, {"role": "user", "content": nonce() + doc(n, 0, needle)
                        + "\n\nWhat is the deployment passphrase mentioned above? Passphrase only."}], 64)
        log({"test": f"maxctx_{n}", "needle_ok": needle.split()[-1].rstrip(".") in (r.get("content") or ""), **r})
