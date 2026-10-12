#!/usr/bin/env node
// dsh-mac-proxy.mjs: the DSH model proxy on 127.0.0.1:1235 (OpenAI-compatible). Source: AI-Server-Docs scripts/.
//
// Since 2026-10-12 every model id goes to Flash-Next on AI Server 2 (Strix Halo, gufo, 262k context). AI Server 1
// (2x RTX 3090) is GPU training only and serves NO LLM: there is no AI Server 1 fallback any more.
//   flash-next (default), qwen3.8-flash-next-uncensored[-strix|-1m], and any other id -> AI Server 2.
// When AI Server 2's model is not up:
//   - asleep: wake it (wake-ai-server-2, bounded), then continue;
//   - a dsh terminal session is live (marker ~/.config/ai-server-2/llm-mode.json < 10 min, written by bin/dsh-llm-mode)
//     or LLM mode is already on there: run `llm-mode on --detach` and wait up to 3 min for the model;
//   - otherwise (scripts, no session): do not evict AI Server 2's Clash jobs; answer 503 saying how to turn it on.
// Every failure is a clear 503 JSON error ("AI Server 2 ..."), never a silent reroute.
// Secrets are read from files at request time, never stored here:
//   ~/.config/ai-server-2/llm_api_key          AI Server 2 bearer key (also /etc/ai-server-2/llm.env on the box)
// Env overrides: DSH_PROXY_PORT, AIS2_URL, WAKE_AIS2 (path of wake-ai-server-2), DSH_PROXY_READY_S.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn, execFile } from 'node:child_process';

const PORT = Number(process.env.DSH_PROXY_PORT || 1235);
const AIS2 = process.env.AIS2_URL || 'http://100.65.60.112:8080';
const WAKE_AIS2 = process.env.WAKE_AIS2 || path.join(os.homedir(), '.local/bin/wake-ai-server-2');
const HOME = os.homedir();
const STATE = path.join(HOME, '.config/ai-server-2/dsh-proxy-state.json');
const LOG = path.join(HOME, 'Library/Logs/dsh-mac-proxy.log');

const MAIN_ID = 'flash-next';
const STRIX_ID = 'qwen3.8-flash-next-uncensored-strix';
const AIS2_MODEL = 'qwen3.8-flash-next-uncensored';

const readKey = (p) => { try { return fs.readFileSync(path.join(HOME, p), 'utf8').trim(); } catch { return ''; } };
const log = (...a) => { try { fs.appendFileSync(LOG, `${new Date().toISOString()} ${a.join(' ')}\n`); } catch {} };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const loadState = () => { try { return JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch { return {}; } };
const saveState = (s) => { try { fs.writeFileSync(STATE, JSON.stringify(s)); } catch {} };

function tcpUp(host, port, ms = 2500) {
  return new Promise((res) => {
    const s = net.connect({ host, port, timeout: ms });
    s.on('connect', () => { s.destroy(); res(true); });
    s.on('timeout', () => { s.destroy(); res(false); });
    s.on('error', () => res(false));
  });
}
const ais2Host = new URL(AIS2).hostname;

async function ais2LlmUp() {
  try {
    const r = await fetch(`${AIS2}/health`, { headers: { Authorization: `Bearer ${readKey('.config/ai-server-2/llm_api_key')}` },
      signal: AbortSignal.timeout(3000) });
    if (r.ok) { const s = loadState(); s.ais2LlmLastUp = Date.now(); saveState(s); }
    return r.ok;
  } catch { return false; }
}

let wakingAis2 = null;
function wakeAis2() {   // wake-ai-server-2 waits for ssh (up to AIS2_WAIT_S); the RTC heartbeat is the floor (<= 20 min)
  if (!wakingAis2) {
    log('waking AI Server 2');
    wakingAis2 = new Promise((res) => {
      const p = spawn(WAKE_AIS2, ['-q'], { stdio: 'ignore', env: { ...process.env, AIS2_WAIT_S: '180' } });
      p.on('exit', (c) => { wakingAis2 = null; res(c === 0); });
      p.on('error', () => { wakingAis2 = null; res(false); });
    });
  }
  return wakingAis2;
}

// LLM mode (2026-10-11): `dsh` (bin/dsh-llm-mode) writes ~/.config/ai-server-2/llm-mode.json {"ts": ms} when AI
// Server 2's LLM mode is on and refreshes it every 5 min while a session lives. While it is fresh (< 10 min; dsh touches every 5),
// flash-next goes ONLY to AI Server 2 (waits for it, never falls back to AI Server 1).
const MODE = path.join(HOME, '.config/ai-server-2/llm-mode.json');
const llmModeOn = () => { try { return Date.now() - JSON.parse(fs.readFileSync(MODE, 'utf8')).ts < 10 * 60e3; } catch { return false; } };
// 2026-10-12: also ask AI Server 2 itself (~/clash-jobs/llm_mode.json "on"), cached 60 s, so a stale Mac marker (no dsh
// session touching it) can never send flash-next to AI Server 1's 3090s (attacker learners) while LLM mode is on there.
let ais2Mode = { t: 0, on: false };
async function ais2ModeOn() {
  if (Date.now() - ais2Mode.t < 60e3) return ais2Mode.on;
  const on = await new Promise((resolve) => {
    execFile('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', 'ai-server-2', 'cat ~/clash-jobs/llm_mode.json'],
      { timeout: 10000 }, (err, out) => { try { resolve(!err && JSON.parse(out).on === true); } catch { resolve(false); } });
  });
  ais2Mode = { t: Date.now(), on };
  return on;
}

const READY_S = Number(process.env.DSH_PROXY_READY_S || 180);
const ssh2 = (cmd, ms = 20000) => new Promise((resolve) => {
  execFile('ssh', ['-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', 'ai-server-2', cmd], { timeout: ms },
    (err, out, se) => resolve({ ok: !err, out: String(out || ''), err: String(se || err?.message || '') }));
});

// Make AI Server 2 serve. Returns null when the model answers, else the error message for a 503.
let ensuring = null;
async function ensureAis2() {
  if (await ais2LlmUp()) return null;
  if (!ensuring) ensuring = (async () => {
    if (!(await tcpUp(ais2Host, 22))) {
      log('AI Server 2 asleep: waking');
      await wakeAis2();
      if (!(await tcpUp(ais2Host, 22)))
        return 'AI Server 2 is asleep or unreachable (wake sent; it also wakes by itself within 20 min). AI Server 1 serves no LLM. Retry in a few minutes';
      if (await ais2LlmUp()) return null;
    }
    ais2Mode.t = 0;
    const session = llmModeOn(), modeOn = await ais2ModeOn();
    if (!session && !modeOn)
      return 'AI Server 2 is not serving Flash-Next (LLM mode off) and AI Server 1 serves no LLM. Start it: run `dsh` in a terminal, or `ssh ai-server-2 llm-mode on` (moves AI Server 2 Clash jobs off)';
    const r = await ssh2('llm-mode on --detach', 30000);
    log(`llm-mode on --detach (${session ? 'dsh session' : 'mode on, model down'}): ${(r.out || r.err).trim().slice(0, 120)}`);
    const t0 = Date.now();
    while (Date.now() - t0 < READY_S * 1000) { if (await ais2LlmUp()) return null; await sleep(5000); }
    const st = await ssh2('llm-mode status', 20000);
    return `Flash-Next on AI Server 2 is not up after ${READY_S} s (LLM mode is on; it moves Clash jobs off, then loads ~60 s). ${st.out.split('\n')[0].slice(0, 160)}. Retry shortly`;
  })().finally(() => { ensuring = null; });
  return ensuring;
}

let lastAis2Use = 0;
setInterval(() => { if (Date.now() - lastAis2Use < 30 * 60e3) ais2LlmUp(); }, 5 * 60e3).unref();

function send(res, code, obj) { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); }

async function forward(req, res, base, key, body) {
  const url = base + req.url;
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` };
  const ctl = new AbortController();
  res.on('close', () => { if (!res.writableEnded) ctl.abort(); });
  const r = await fetch(url, { method: req.method, headers, body: body ? JSON.stringify(body) : undefined, signal: ctl.signal });
  const h = {}; r.headers.forEach((v, k) => { if (!['content-length', 'content-encoding', 'transfer-encoding', 'connection'].includes(k)) h[k] = v; });
  res.writeHead(r.status, h);
  if (r.body) { for await (const chunk of r.body) res.write(chunk); }
  res.end();
}

async function listModels() {
  return { object: 'list', data: [
    { id: MAIN_ID, object: 'model', owned_by: 'ai-server-2', description: 'Qwen3.8-Flash-Next uncensored on AI Server 2 (gufo)', context_length: 262144 },
    { id: STRIX_ID, object: 'model', owned_by: 'ai-server-2', description: 'same as flash-next', context_length: 262144 },
  ] };
}

http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && (req.url === '/v1/models' || req.url === '/models')) return send(res, 200, await listModels());
    if (req.method === 'GET' && req.url === '/health') return send(res, 200, { status: 'ok', ais2_llm: await ais2LlmUp() });
    if (req.method !== 'POST') return send(res, 404, { error: { message: 'not found' } });
    let raw = ''; for await (const c of req) raw += c;
    const body = raw ? JSON.parse(raw) : {};
    const want = String(body.model || MAIN_ID);
    const bad = await ensureAis2();
    if (bad) { log(`503 ${want}: ${bad.slice(0, 100)}`); return send(res, 503, { error: { message: bad, type: 'model_proxy_error', code: 'ai_server_2_not_serving' } }); }
    lastAis2Use = Date.now();
    log(`-> ais2 ${want}`);
    return await forward(req, res, AIS2, readKey('.config/ai-server-2/llm_api_key'), { ...body, model: AIS2_MODEL });
  } catch (e) {
    log('error', e?.message || e);
    if (!res.headersSent) send(res, 502, { error: { message: String(e?.message || e), type: 'model_proxy_error' } });
    else res.end();
  }
}).listen(PORT, '127.0.0.1', () => log(`dsh-mac-proxy listening on 127.0.0.1:${PORT}`));
