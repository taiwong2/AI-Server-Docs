"""as2_llm_relay.py: AI Server 1's only LLM endpoint. It forwards to Flash-Next on AI Server 2 and serves no model itself.

Since 2026-10-12, AI Server 1 (2x RTX 3090) does GPU training only. No LM Studio, llama.cpp, Ollama or model proxy
runs here unless the user says otherwise (marker C:\\AI-Server\\state\\as1-llm.allowed). Every consumer that used to
call an LLM on this box now calls this relay, which forwards to AI Server 2's gufo server (OpenAI-compatible,
http://100.65.60.112:8080). The relay injects AI Server 2's API key on the server side, so no caller ever sees it.

Listeners (profiles):
  dev       127.0.0.1:1234 + 100.71.113.77:1234   Antoine's pp-antoine (its firewall allows loopback 1234) and his
                                                   tailnet devices (sharee rule allows 1234). It replaces LM Studio's
                                                   old :1234. Strict caps: max_tokens, rate, daily busy time, LLM-mode
                                                   activations, a context guard and a loop breaker.
  internal  127.0.0.1:1240                         AI Server 1's own consumers (qwen-agent / Discord qwen-* channels,
                                                   qwenresearch jobs, kp-reviews ai_server writer). Not reachable from
                                                   pp-antoine (its firewall allows only 1234 and 20000-29999).

On demand: when AI Server 2's model is not up, the relay runs `llm-mode on --detach` there over ssh with AI Server 1's
restricted key (forced command /usr/local/bin/clashjobs-ssh: clashjobs, `llm-mode status --json`, `llm-mode on
--detach`, `llm-mode touch` only). That moves, freezes or parks AI Server 2's Clash jobs by lane policy, and
memory-fitting jobs are admitted again beside the model. The relay then waits up to WAIT_READY_S for the model. If AI
Server 2 is asleep, it sends Wake-on-LAN, keeps trying in the background for 25 min (the box also wakes on its 20-min
RTC heartbeat), and answers 503 with Retry-After. Every answer that is not a model reply is a clear JSON error.
AI Server 2's own idle watcher turns LLM mode off after 30 min with no requests, so the relay never pins it.

Context: Flash-Next has 262,144 tokens. Over-long requests fail fast with 400 context_length_exceeded: the relay
rejects anything whose size estimate is clearly over (over 6.5 bytes per token of budget, ~1.7 MB) without touching AI Server 2, and
gufo rejects the rest in about 2 s. A client that gets 3 such errors in 10 min is blocked for 15 min, and a 4th identical prompt within 10 min is refused
(loop breakers). Rejected requests never reach AI Server 2, so they never count as LLM use there.

Endpoints: GET /health (relay only), GET /status (AI Server 2 state, budget), GET /v1/models, POST
/v1/chat/completions, /v1/completions, /v1/responses (+ /v1/messages on internal). Any requested model id is served by
qwen3.8-flash-next-uncensored (the reply's `model` says so).

Config overrides: C:\\AI-Server\\state\\as2-llm-relay\\config.json (same keys as DEFAULTS). Key file:
C:\\AI-Server\\state\\as2-llm-relay\\llm_api_key (ACL poopl/SYSTEM/Administrators). Log: C:\\AI-Server\\logs\\as2-llm-relay.log
(metadata only, never prompt text). Usage counters: state\\as2-llm-relay\\usage.json.
Run: task \\AI-LLMRelay (poopl, at startup). Stdlib only.
"""
from __future__ import annotations

import http.client
import hashlib
import json
import os
import socket
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(r"C:\AI-Server")
STATE = ROOT / "state" / "as2-llm-relay"
LOGF = ROOT / "logs" / "as2-llm-relay.log"
MODEL = "qwen3.8-flash-next-uncensored"
CTX = 262144

DEFAULTS = {
    "as2_host": "100.65.60.112",
    "as2_port": 8080,
    "ssh_key": r"C:\AI-Server\state\ssh\ai-server-2_ed25519",
    "known_hosts": r"C:\AI-Server\state\ssh\known_hosts",
    "wake_macs": ["cc:61:46:b6:34:c5", "38:05:25:31:90:8a", "38:05:25:31:90:8b"],
    "wait_ready_s": 170,          # how long one request waits for the model after LLM mode was asked for
    "bytes_per_token_floor": 6.5,  # body bytes / this > CTX (~1.7 MB) => certainly too long (rejected without AS2)
    "profiles": {
        "dev": {
            "binds": [["127.0.0.1", 1234], ["100.71.113.77", 1234]],
            "max_output_tokens": 8192,       # clamp (also the default when the client sends none)
            "max_body_mb": 6,
            "concurrency": 1,                # one generation at a time; others wait queue_wait_s, then 429
            "queue_wait_s": 120,
            "per_minute": 6,
            "per_hour": 60,
            "per_day": 400,
            "busy_s_per_day": 3 * 3600,      # summed request wall time per box-local day
            "activations_per_day": 4,        # how many times this profile may switch AS2's LLM mode on per day
            "upstream_timeout_s": 900,
            "paths": ["/v1/chat/completions", "/v1/completions", "/v1/responses"],
        },
        "internal": {
            "binds": [["127.0.0.1", 1240]],
            "max_output_tokens": 32768,
            "max_body_mb": 8,
            "concurrency": 2,
            "queue_wait_s": 900,
            "per_minute": 60,
            "per_hour": 1000,
            "per_day": 10000,
            "busy_s_per_day": 24 * 3600,
            "activations_per_day": 48,
            "upstream_timeout_s": 1800,
            "paths": ["/v1/chat/completions", "/v1/completions", "/v1/responses", "/v1/messages"],
        },
    },
}


def load_cfg():
    cfg = json.loads(json.dumps(DEFAULTS))
    try:
        over = json.loads((STATE / "config.json").read_text(encoding="utf-8"))
        for k, v in over.items():
            if k == "profiles":
                for p, pv in v.items():
                    cfg["profiles"].setdefault(p, {}).update(pv)
            else:
                cfg[k] = v
    except FileNotFoundError:
        pass
    return cfg


CFG = load_cfg()
_log_lock = threading.Lock()


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    with _log_lock:
        try:
            LOGF.parent.mkdir(parents=True, exist_ok=True)
            with open(LOGF, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def api_key():
    try:
        return (STATE / "llm_api_key").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


# ----------------------------------------------------------------------------------------------- usage / limits
_usage_lock = threading.Lock()


def _today():
    return time.strftime("%Y-%m-%d")


def usage_load():
    try:
        u = json.loads((STATE / "usage.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        u = {}
    if u.get("day") != _today():
        u = {"day": _today(), "profiles": {}}
    return u


def usage_save(u):
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        tmp = STATE / "usage.json.tmp"
        tmp.write_text(json.dumps(u, indent=1), encoding="utf-8")
        os.replace(tmp, STATE / "usage.json")
    except OSError:
        pass


def usage_add(profile, **inc):
    with _usage_lock:
        u = usage_load()
        p = u["profiles"].setdefault(profile, {"requests": 0, "busy_s": 0.0, "activations": 0, "prompt_tokens": 0,
                                               "completion_tokens": 0, "rejected": 0})
        for k, v in inc.items():
            p[k] = p.get(k, 0) + v
        usage_save(u)
        return dict(p)


def usage_get(profile):
    with _usage_lock:
        return dict(usage_load()["profiles"].get(profile, {}))


class Limiter:
    """Sliding-window request counts and the context-error loop breaker, per profile (in memory)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.reqs = {}
        self.ctx_errs = {}
        self.blocked_until = {}
        self.hashes = {}

    def repeat(self, profile, digest):
        """More than 3 identical prompts in 10 min = a looping client: refuse the 4th and later for 10 min."""
        now = time.time()
        with self.lock:
            q = self.hashes.setdefault(profile, deque())
            while q and now - q[0][0] > 600:
                q.popleft()
            n = sum(1 for _, h in q if h == digest)
            if n >= 3:
                return n
            q.append((now, digest))
        return 0

    def check(self, profile, pc):
        now = time.time()
        with self.lock:
            if self.blocked_until.get(profile, 0) > now:
                left = int(self.blocked_until[profile] - now)
                return (f"blocked for {left} s more: 3 requests in 10 min exceeded the 262,144-token context. "
                        "Compact or shorten the conversation before retrying."), left
            q = self.reqs.setdefault(profile, deque())
            while q and now - q[0] > 3600:
                q.popleft()
            last_min = sum(1 for t in q if now - t < 60)
            if last_min >= pc["per_minute"]:
                return f"rate limit: {pc['per_minute']} requests per minute", 30
            if len(q) >= pc["per_hour"]:
                return f"rate limit: {pc['per_hour']} requests per hour", int(3600 - (now - q[0])) + 1
            q.append(now)
        return None, 0

    def ctx_error(self, profile):
        now = time.time()
        with self.lock:
            q = self.ctx_errs.setdefault(profile, deque())
            q.append(now)
            while q and now - q[0] > 600:
                q.popleft()
            if len(q) >= 3:
                self.blocked_until[profile] = now + 900
                q.clear()
                log(f"[{profile}] loop breaker: 3 context_length_exceeded in 10 min, blocked 15 min")


LIMITER = Limiter()
SLOTS = {}


# ----------------------------------------------------------------------------------------------- AI Server 2
_health = {"t": 0.0, "up": False}
_ensure_lock = threading.Lock()
_waker = {"thread": None, "since": 0.0, "profile": None}


def as2_conn(timeout):
    return http.client.HTTPConnection(CFG["as2_host"], CFG["as2_port"], timeout=timeout)


def as2_up(max_age=15.0):
    if time.time() - _health["t"] < max_age:
        return _health["up"]
    up = False
    try:
        c = as2_conn(4)
        c.request("GET", "/health", headers={"Authorization": f"Bearer {api_key()}"})
        r = c.getresponse()
        r.read()
        up = r.status == 200
        c.close()
    except (OSError, http.client.HTTPException):
        up = False
    _health.update(t=time.time(), up=up)
    return up


def ssh_box(cmd, timeout=25):
    """Run one allowed command on AI Server 2 through the forced-command key. Returns (rc, stdout, stderr)."""
    args = ["ssh", "-i", CFG["ssh_key"], "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", f"UserKnownHostsFile={CFG['known_hosts']}", "-o", "StrictHostKeyChecking=accept-new",
            f"taiwong@{CFG['as2_host']}", cmd]
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 255, "", "ssh timed out"
    except OSError as e:
        return 255, "", str(e)


def llm_status():
    rc, out, err = ssh_box("llm-mode status --json")
    if rc == 255:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return {"error": (err or out).strip()[:300]}


def send_wol():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for mac in CFG["wake_macs"]:
            mb = bytes(int(x, 16) for x in mac.split(":"))
            pkt = b"\xff" * 6 + mb * 16
            for port in (9, 7):
                for dst in ("192.168.1.255", "255.255.255.255"):
                    try:
                        s.sendto(pkt, (dst, port))
                    except OSError:
                        pass
        s.close()
    except OSError:
        pass


def activate(profile):
    """Ask AI Server 2 for LLM mode (detached). Returns an error string, or None."""
    pc = CFG["profiles"][profile]
    if usage_get(profile).get("activations", 0) >= pc["activations_per_day"]:
        return (f"this endpoint may switch AI Server 2's LLM mode on at most {pc['activations_per_day']} times a day, "
                "and that budget is used up; the model is off. It resets at midnight (AI Server 1 time)")
    rc, out, err = ssh_box("llm-mode on --detach")
    if rc == 3 or "REFUSED" in out:
        # 2026-10-12: the model cannot fit now (training hubs hold AI Server 2's memory) or a load just failed; LLM
        # mode stays off and AI Server 2 refuses turn-ons until its cooldown ends
        return out.strip().splitlines()[-1].replace("llm-mode on: ", "", 1)[:500] if out.strip() else "llm-mode on refused"
    if rc != 0:
        return f"llm-mode on failed on AI Server 2 (rc {rc}): {(err or out).strip()[:300]}"
    usage_add(profile, activations=1)
    log(f"[{profile}] llm-mode on --detach: {out.strip()[:120]}")
    return None


def background_waker(profile):
    """AI Server 2 is asleep: keep sending WoL and trying ssh for 25 min, then ask for LLM mode once it answers."""
    t0 = time.time()
    while time.time() - t0 < 25 * 60:
        send_wol()
        st = llm_status()
        if st is not None:
            if not st.get("on") and st.get("model") != "up":
                err = activate(profile)
                log(f"[{profile}] AI Server 2 awake after {time.time() - t0:.0f} s; " + (err or "LLM mode requested"))
            else:
                log(f"[{profile}] AI Server 2 awake after {time.time() - t0:.0f} s; LLM mode already on")
            break
        time.sleep(30)
    else:
        log(f"[{profile}] AI Server 2 did not wake within 25 min")
    _waker.update(thread=None)


def ensure_ready(profile):
    """Returns None when AI Server 2's model answers, else (http_code, message, retry_after_s)."""
    if as2_up():
        return None
    with _ensure_lock:
        if as2_up(max_age=0):
            return None
        if _waker["thread"] is not None:
            return 503, (f"AI Server 2 is asleep; waking it (started {time.time() - _waker['since']:.0f} s ago; it also "
                         "wakes by itself within 20 min). LLM mode will be switched on when it answers"), 120
        st = llm_status()
        if st is None:
            send_wol()
            _waker.update(since=time.time(), profile=profile,
                          thread=threading.Thread(target=background_waker, args=(profile,), daemon=True))
            _waker["thread"].start()
            log(f"[{profile}] AI Server 2 unreachable over ssh: WoL sent, background waker started")
            return 503, ("AI Server 2 is asleep or unreachable; a wake was sent (it also wakes by itself within 20 "
                         "min). LLM mode will be switched on when it answers. Retry in a few minutes"), 180
        if st.get("error"):
            return 503, f"AI Server 2 answered but llm-mode status failed: {st['error']}", 120
        if not st.get("on") and not st.get("starting"):
            err = activate(profile)
            if err:
                return 503, err, 3600
    # wait for the model (outside the lock: other requests may wait too)
    t0, chk = time.time(), time.time()
    while time.time() - t0 < CFG["wait_ready_s"]:
        if as2_up(max_age=0):
            log(f"[{profile}] AI Server 2 model up after {time.time() - t0:.0f} s")
            return None
        if time.time() - chk > 30:                   # llm-mode gave up (off + cooldown): answer at once
            chk = time.time()
            st = llm_status() or {}
            if not st.get("on") and st.get("cooldown_until"):
                return 503, (f"AI Server 2 gave up loading Flash-Next: {st.get('last_failure')} "
                             f"Retry after {st['cooldown_until']}"), 1200
        time.sleep(5)
    st = llm_status() or {}
    return 503, ("Flash-Next is still loading on AI Server 2 (LLM mode on; it first moves or freezes Clash jobs, then "
                 f"loads ~60 s). Last: {str(st.get('last_log', ''))[:160]!r}. Retry in a minute"), 60


# ----------------------------------------------------------------------------------------------- HTTP
OUT_KEYS = {"/v1/chat/completions": ("max_tokens", "max_completion_tokens"), "/v1/completions": ("max_tokens",),
            "/v1/responses": ("max_output_tokens",), "/v1/messages": ("max_tokens",)}


def make_handler(profile):
    pc = CFG["profiles"][profile]

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"     # one request per connection; streaming ends with the close
        server_version = "as2-llm-relay"

        def log_message(self, *a):
            pass

        def err(self, code, message, etype="relay_error", ecode=None, retry_after=None):
            body = json.dumps({"error": {"message": f"[AI Server 1 relay -> AI Server 2 Flash-Next] {message}",
                                         "type": etype, "code": ecode or etype}}).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if retry_after:
                self.send_header("Retry-After", str(int(retry_after)))
            self.end_headers()
            self.wfile.write(body)

        def json_ok(self, obj):
            body = json.dumps(obj).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0].rstrip("/")
            if path in ("/v1/models", "/models"):
                return self.json_ok({"object": "list", "data": [
                    {"id": MODEL, "object": "model", "owned_by": "ai-server-2", "context_length": CTX,
                     "max_output_tokens": pc["max_output_tokens"]}]})
            if path == "/health":
                return self.json_ok({"status": "ok", "profile": profile, "as2_model_up": as2_up()})
            if path == "/status":
                u = usage_get(profile)
                return self.json_ok({"profile": profile, "model": MODEL, "context": CTX, "as2_model_up": as2_up(),
                                     "limits": {k: pc[k] for k in ("max_output_tokens", "per_minute", "per_hour",
                                                                     "per_day", "busy_s_per_day", "activations_per_day")},
                                     "today": u})
            return self.err(404, f"no route {path}; this relay serves /v1/models and {', '.join(pc['paths'])}",
                            "invalid_request_error", "not_found")

        def do_POST(self):
            t0 = time.time()
            path = self.path.split("?")[0].rstrip("/")
            client = self.client_address[0]
            if path not in pc["paths"]:
                return self.err(404, f"no route {path}; use one of {', '.join(pc['paths'])}", "invalid_request_error",
                                "not_found")
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = 0
            if n <= 0:
                return self.err(411, "Content-Length is required", "invalid_request_error")
            if n > pc["max_body_mb"] * 1024 * 1024 or n / CFG["bytes_per_token_floor"] > CTX:
                usage_add(profile, rejected=1)
                LIMITER.ctx_error(profile)
                log(f"[{profile}] {client} {path} REJECT body {n} B (~{n / 4:.0f} tok est) > context")
                # drain a bounded amount so the client sees the reply instead of a reset
                try:
                    self.rfile.read(min(n, 16 * 1024 * 1024))
                except OSError:
                    pass
                return self.err(400, (f"request is about {n / 4:,.0f} tokens ({n:,} bytes); Flash-Next's context is "
                                      f"{CTX:,} tokens. Compact or truncate the conversation; retrying unchanged "
                                      "will fail the same way"), "invalid_request_error", "context_length_exceeded")
            raw = self.rfile.read(n)
            try:
                body = json.loads(raw)
                assert isinstance(body, dict)
            except (ValueError, AssertionError):
                return self.err(400, "body is not a JSON object", "invalid_request_error")
            digest = hashlib.sha256(json.dumps({k: body.get(k) for k in ("messages", "prompt", "input", "system")},
                                               sort_keys=True).encode()).hexdigest()
            rep = LIMITER.repeat(profile, digest)
            if rep:
                usage_add(profile, rejected=1)
                log(f"[{profile}] {client} {path} 429 same prompt {rep + 1}x in 10 min ({digest[:10]})")
                return self.err(429, (f"the same prompt arrived {rep + 1} times in 10 min; this looks like a retry "
                                      "loop. Change the request or wait 10 min"), "rate_limit_error", "repeated_prompt", 600)
            why, retry = LIMITER.check(profile, pc)
            if why:
                usage_add(profile, rejected=1)
                log(f"[{profile}] {client} {path} 429 {why}")
                return self.err(429, why, "rate_limit_error", "rate_limited", retry)
            u = usage_get(profile)
            if u.get("requests", 0) >= pc["per_day"]:
                return self.err(429, f"daily limit of {pc['per_day']} requests reached (resets at midnight)",
                                "rate_limit_error", "rate_limited", 3600)
            if u.get("busy_s", 0) >= pc["busy_s_per_day"]:
                return self.err(429, (f"daily budget of {pc['busy_s_per_day'] / 3600:.1f} h of model time reached; "
                                      "it resets at midnight (AI Server 1 time)"), "rate_limit_error", "rate_limited", 3600)
            asked = body.get("model")
            body["model"] = MODEL
            keys = OUT_KEYS.get(path, ("max_tokens",))
            req_out = [body[k] for k in keys if isinstance(body.get(k), int) and body[k] > 0]
            cap = min(req_out + [pc["max_output_tokens"]])
            present = [k for k in keys if k in body] or [keys[0]]
            for k in present:
                body[k] = cap
            stream = bool(body.get("stream"))
            if stream and path == "/v1/chat/completions":
                body.setdefault("stream_options", {}).setdefault("include_usage", True)
            data = json.dumps(body).encode()

            slot = SLOTS[profile]
            if not slot.acquire(timeout=pc["queue_wait_s"]):
                return self.err(429, f"busy: {pc['concurrency']} request(s) already running here; retry shortly",
                                "rate_limit_error", "busy", 30)
            try:
                bad = ensure_ready(profile)
                if bad:
                    code, msg, ra = bad
                    log(f"[{profile}] {client} {path} {code} {msg[:120]}")
                    return self.err(code, msg, "service_unavailable", "ai_server_2_not_serving", ra)
                return self.forward(path, data, stream, asked, t0, client)
            finally:
                slot.release()

        def forward(self, path, data, stream, asked, t0, client):
            usage_add(profile, requests=1)
            status, ptok, ctok = 0, 0, 0
            try:
                c = as2_conn(pc["upstream_timeout_s"])
                c.request("POST", path, body=data, headers={"Content-Type": "application/json",
                                                            "Authorization": f"Bearer {api_key()}",
                                                            "Accept": self.headers.get("Accept", "*/*")})
                r = c.getresponse()
                status = r.status
                self.send_response(r.status)
                for k, v in r.getheaders():
                    if k.lower() not in ("content-length", "transfer-encoding", "connection", "content-encoding"):
                        self.send_header(k, v)
                self.send_header("X-Relay-Model", MODEL)
                self.send_header("Connection", "close")
                self.end_headers()
                tail = b""
                if r.status != 200 or not stream:
                    payload = r.read()
                    self.wfile.write(payload)
                    tail = payload[-4000:]
                    if r.status == 400 and b"context_length_exceeded" in payload:
                        LIMITER.ctx_error(profile)
                else:
                    while True:
                        chunk = r.read1(65536) if hasattr(r, "read1") else r.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        tail = (tail + chunk)[-8000:]
                c.close()
                ptok, ctok = usage_from(tail)
            except (BrokenPipeError, ConnectionResetError):
                log(f"[{profile}] {client} {path} client went away")
            except (OSError, http.client.HTTPException) as e:
                _health.update(t=0)
                if not status:
                    return self.err(502, f"AI Server 2 request failed: {e.__class__.__name__}: {e}",
                                    "service_unavailable", "upstream_error", 30)
            finally:
                dt = time.time() - t0
                usage_add(profile, busy_s=round(dt, 1), prompt_tokens=ptok, completion_tokens=ctok)
                log(f"[{profile}] {client} {path} model={asked!r} -> {status} {dt:.1f}s stream={stream} "
                    f"prompt={ptok} completion={ctok}")

    return H


def usage_from(tail: bytes):
    """prompt/completion token counts from the end of a reply (JSON body or SSE stream with a usage chunk)."""
    txt = tail.decode("utf-8", "ignore")
    i = txt.rfind('"usage"')
    if i < 0:
        return 0, 0
    seg = txt[i:i + 600]

    def num(key):
        j = seg.find(f'"{key}"')
        if j < 0:
            return 0
        k = seg.find(":", j) + 1
        d = ""
        for ch in seg[k:].lstrip():
            if ch.isdigit():
                d += ch
            else:
                break
        return int(d or 0)
    return num("prompt_tokens") or num("input_tokens"), num("completion_tokens") or num("output_tokens")


def serve():
    servers = []
    for name, pc in CFG["profiles"].items():
        SLOTS[name] = threading.BoundedSemaphore(pc["concurrency"])
        for host, port in pc["binds"]:
            for attempt in range(60):
                try:
                    srv = ThreadingHTTPServer((host, port), make_handler(name))
                    break
                except OSError as e:
                    if attempt == 0:
                        log(f"bind {host}:{port} failed ({e}); retrying for 10 min")
                    time.sleep(10)
            else:
                log(f"bind {host}:{port} gave up")
                continue
            srv.daemon_threads = True
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            servers.append(srv)
            log(f"listening {host}:{port} profile={name}")
    if not servers:
        log("no listener bound; exiting")
        return 1
    if not api_key():
        log(f"WARNING: no key at {STATE / 'llm_api_key'}; AI Server 2 will answer 401")
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    sys.exit(serve())
