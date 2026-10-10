#!/usr/bin/env node
// dsh-mac-proxy.mjs: the Mac DSH model proxy on 127.0.0.1:1235 (OpenAI-compatible).
//
// Routes:
//   flash-next                          main entry. AI Server 2 (Strix Halo, gufo) when its LLM is up,
//                                       otherwise AI Server 1's qwen3.8-flash-next-uncensored (fallback).
//   qwen3.8-flash-next-uncensored-strix AI Server 2 only (on demand). Wakes the box, waits for the model.
//   anything else                       AI Server 1's model proxy (:1235), which starts/switches its native
//                                       llama.cpp host and owns the GPU leases itself. Wakes AI Server 1.
// AI Server 2 needs no GPU lease (one GPU, one model). While a request to it ran in the last 30 min the
// proxy polls its /health every 5 min, which the box's power daemon counts as LLM activity (keeps it awake).
//
// Secrets are read from files at request time, never stored here:
//   ~/.config/ai-server-2/llm_api_key          AI Server 2 bearer key (also /etc/ai-server-2/llm.env on the box)
//   ~/.config/ai-server/model_proxy_api_key    a key in AI Server 1's C:\AI-Server\scripts\.api-key
// Env overrides: DSH_PROXY_PORT, AIS2_URL, AIS1_URL, AIS1_WAKE_URL, WAKE_AIS2 (path of wake-ai-server-2).
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn } from 'node:child_process';

const PORT = Number(process.env.DSH_PROXY_PORT || 1235);
const AIS2 = process.env.AIS2_URL || 'http://100.65.60.112:8080';
const AIS1 = process.env.AIS1_URL || 'http://100.71.113.77:1235';
const AIS1_WAKE = process.env.AIS1_WAKE_URL || 'https://wake-relay.tail215694.ts.net/wake';
const WAKE_AIS2 = process.env.WAKE_AIS2 || path.join(os.homedir(), '.local/bin/wake-ai-server-2');
const HOME = os.homedir();
const STATE = path.join(HOME, '.config/ai-server-2/dsh-proxy-state.json');
const LOG = path.join(HOME, 'Library/Logs/dsh-mac-proxy.log');

const MAIN_ID = 'flash-next';
const STRIX_ID = 'qwen3.8-flash-next-uncensored-strix';
const AIS2_MODEL = 'qwen3.8-flash-next-uncensored';
const AIS1_FLASH = 'qwen3.8-flash-next-uncensored';

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
      const p = spawn(WAKE_AIS2, ['-q'], { stdio: 'ignore', env: { ...process.env, AIS2_WAIT_S: '1500' } });
      p.on('exit', (c) => { wakingAis2 = null; res(c === 0); });
      p.on('error', () => { wakingAis2 = null; res(false); });
    });
  }
  return wakingAis2;
}

// Decide where flash-next goes right now.
async function mainRoute() {
  if (await ais2LlmUp()) return 'ais2';
  const awake = await tcpUp(ais2Host, 22);
  const s = loadState();
  // asleep, and its LLM was serving in the last 2 days: wake it for next time, answer from AI Server 1 now
  if (!awake && s.ais2LlmLastUp && Date.now() - s.ais2LlmLastUp < 2 * 86400e3) wakeAis2();
  return 'ais1';
}

// Strix-only route: wake, then wait for the model (loads in ~30 s once llm.target is on).
async function ensureAis2() {
  if (await ais2LlmUp()) return true;
  if (!(await tcpUp(ais2Host, 22))) await wakeAis2();
  for (let i = 0; i < 24; i++) { if (await ais2LlmUp()) return true; await sleep(5000); }
  return false;
}

let lastAis2Use = 0;
setInterval(() => { if (Date.now() - lastAis2Use < 30 * 60e3) ais2LlmUp(); }, 5 * 60e3).unref();

async function ensureAis1() {
  if (await tcpUp(new URL(AIS1).hostname, Number(new URL(AIS1).port || 80))) return true;
  log('waking AI Server 1 via relay');
  try { await fetch(AIS1_WAKE, { signal: AbortSignal.timeout(15000) }); } catch {}
  for (let i = 0; i < 60; i++) { await sleep(5000); if (await tcpUp(new URL(AIS1).hostname, Number(new URL(AIS1).port))) return true; }
  return false;
}

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
  const data = [
    { id: MAIN_ID, object: 'model', owned_by: 'dsh-mac-proxy', description: 'Flash-Next uncensored: AI Server 2 when on, else AI Server 1' },
    { id: STRIX_ID, object: 'model', owned_by: 'ai-server-2', description: 'AI Server 2 gufo (on demand)', context_length: 262144 },
  ];
  try {
    const r = await fetch(`${AIS1}/v1/models`, { headers: { Authorization: `Bearer ${readKey('.config/ai-server/model_proxy_api_key')}` }, signal: AbortSignal.timeout(5000) });
    const j = await r.json();
    for (const m of j.data || []) data.push({ ...m, owned_by: 'ai-server' });
  } catch { for (const id of ['qwen3.8-27b-uncensored', AIS1_FLASH, `${AIS1_FLASH}-1m`]) data.push({ id, object: 'model', owned_by: 'ai-server' }); }
  return { object: 'list', data };
}

http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && (req.url === '/v1/models' || req.url === '/models')) return send(res, 200, await listModels());
    if (req.method === 'GET' && req.url === '/health') return send(res, 200, { status: 'ok', ais2_llm: await ais2LlmUp() });
    if (req.method !== 'POST') return send(res, 404, { error: { message: 'not found' } });
    let raw = ''; for await (const c of req) raw += c;
    const body = raw ? JSON.parse(raw) : {};
    const want = String(body.model || MAIN_ID);
    let route = 'ais1';
    if (want === STRIX_ID) route = 'ais2-only';
    else if (want === MAIN_ID || want === 'default') route = await mainRoute();
    if (route.startsWith('ais2')) {
      if (route === 'ais2-only' && !(await ensureAis2()))
        return send(res, 503, { error: { message: 'AI Server 2 LLM is off. Turn it on: ssh ai-server-2 sudo systemctl enable --now llm.target', type: 'model_proxy_error' } });
      lastAis2Use = Date.now();
      log(`-> ais2 ${want}`);
      return await forward(req, res, AIS2, readKey('.config/ai-server-2/llm_api_key'), { ...body, model: AIS2_MODEL });
    }
    if (!(await ensureAis1())) return send(res, 503, { error: { message: 'AI Server 1 did not wake', type: 'model_proxy_error' } });
    const model = (want === MAIN_ID || want === 'default') ? AIS1_FLASH : want;
    log(`-> ais1 ${model}`);
    return await forward(req, res, AIS1, readKey('.config/ai-server/model_proxy_api_key'), { ...body, model });
  } catch (e) {
    log('error', e?.message || e);
    if (!res.headersSent) send(res, 502, { error: { message: String(e?.message || e), type: 'model_proxy_error' } });
    else res.end();
  }
}).listen(PORT, '127.0.0.1', () => log(`dsh-mac-proxy listening on 127.0.0.1:${PORT}`));
