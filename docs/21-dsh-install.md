# Installing dsh (DeepSeek Harness client) on another machine

How to install the `dsh` client so that typing `dsh` behaves as it does on the user's Mac: it turns on AI Server 2's
**LLM mode**, which moves AI Server 2's Clash jobs off and loads Flash-Next. It runs the session against `flash-next`
on AI Server 2, and AI Server 2 unloads the model by itself after 30 idle minutes. How it works:
[docs/10](10-dsh-setup.md#ai-server-2-is-the-default-backend-llm-mode) and [docs/17](17-ai-server-2-llm.md).
The client runs no model. All inference happens on AI Server 2 (AI Server 1 only as a fallback for scripts).

Tested 2026-10-12: a fresh install into an empty `HOME` on the Mac (macOS 26, node 22), steps 1-6 below; Windows on
TPC (see [Windows](#windows-tpc)).

## 1. Prerequisites

| | |
|---|---|
| Node.js | 22.x (`node -v`). macOS: nvm or Homebrew. Linux: nodesource or nvm. Windows: the official MSI |
| ssh | OpenSSH client with a key that AI Server 2's `taiwong` accepts (`~/.ssh/authorized_keys` on the box) |
| Tailscale | joined to the tailnet (`tail215694`): AI Server 2 is `100.65.60.112` (`ai-server-2`), AI Server 1 is `100.71.113.77` |
| bash, curl | macOS / Linux: built in. Windows: see the Windows section |

ssh alias (`~/.ssh/config`), so `ssh ai-server-2 llm-mode status` works:

```
Host ai-server-2
  HostName 100.65.60.112
  User taiwong
```

## 2. The harness

The Mac install is `~/Documents/deepseek-harness`. A new machine needs the same layout (root anywhere):

```
<root>/package.json        {"dependencies": {"@deepseek-ai/dsh": "0.1.5-rc.1"}}
<root>/node_modules/       npm install
<root>/bin/dsh             wrapper            (this repo: scripts/dsh/dsh.zsh)
<root>/bin/dsh-llm-mode    LLM-mode hook      (scripts/dsh/dsh-llm-mode)
<root>/bin/dsh-mac-proxy.mjs  local proxy :1235 (scripts/dsh-mac-proxy.mjs)
<root>/home/cordis.patch.yml  provider config (scripts/dsh/cordis.patch.yml): tai-ai-server -> 127.0.0.1:1235, default flash-next
```

```bash
R=~/deepseek-harness; D=<path to this repo>/scripts
mkdir -p $R/bin $R/home ~/.local/bin && cd $R
printf '{"dependencies":{"@deepseek-ai/dsh":"0.1.5-rc.1"}}\n' > package.json && npm install
cp $D/dsh/dsh.zsh $R/bin/dsh; cp $D/dsh/dsh-llm-mode $D/dsh-mac-proxy.mjs $R/bin/; chmod +x $R/bin/*
cp $D/dsh/cordis.patch.yml $R/home/
ln -sfn $R/bin/dsh ~/.local/bin/dsh            # ~/.local/bin on PATH
```

The wrapper finds its root from its own path (symlinks resolved), so no paths need editing. `DSH_HOME` is
`<root>/home`. Profiles (`home/profiles/*`) are created on first run. Do not copy `sessions/` or `storages/` from
another machine. On Linux without zsh: install zsh, or port the 30-line wrapper to bash (`${0:A:h:h}` becomes
`$(dirname "$(dirname "$(readlink -f "$0")")")`).

## 3. API keys (never in a repo, never pasted)

| file (mode 600) | what | where the value comes from |
|---|---|---|
| `~/.config/ai-server-2/llm_api_key` | AI Server 2 gufo bearer key | `/etc/ai-server-2/llm.env` on the box (`LLM_API_KEY=`, root 600), or copy the file from the Mac |
| `~/.config/ai-server/model_proxy_api_key` | AI Server 1 model-proxy key (fallback) | a dedicated line in AI Server 1's `C:\AI-Server\scripts\.api-key` (add one per machine so it can be revoked) |

Copy them file to file (`scp mac:.config/ai-server-2/llm_api_key ~/.config/ai-server-2/ && chmod 600 ...`). Do not
echo them. The proxy reads them at request time.

## 4. The proxy as a service

macOS: `scripts/dsh/com.tai.dsh-mac-proxy.plist` into `~/Library/LaunchAgents/` (fix the node and script paths), then
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tai.dsh-mac-proxy.plist`. Restart after an edit:
`launchctl kickstart -k gui/$(id -u)/com.tai.dsh-mac-proxy`. Log: `~/Library/Logs/dsh-mac-proxy.log`.

Linux (systemd user unit `~/.config/systemd/user/dsh-proxy.service`):

```
[Unit]
Description=dsh model proxy (127.0.0.1:1235)
[Service]
ExecStart=/usr/bin/node %h/deepseek-harness/bin/dsh-mac-proxy.mjs
Restart=always
[Install]
WantedBy=default.target
```
`systemctl --user enable --now dsh-proxy; loginctl enable-linger $USER`. The log goes to
`~/Library/Logs/dsh-mac-proxy.log` (the path is fixed in the script; `mkdir -p ~/Library/Logs`).

## 5. The LLM-mode hook

Nothing else to install. When stdin and stdout are a terminal, `bin/dsh` calls `bin/dsh-llm-mode on`: it wakes AI
Server 2 (via `wake-ai-server-2`, if installed; otherwise it retries ssh for up to 25 min), runs `llm-mode on` there,
and writes `~/.config/ai-server-2/llm-mode.json`. While that file is under 10 min old, the proxy sends `flash-next`
only to AI Server 2. The wrapper touches the box every 5 min during the session. Scripts (no TTY) and
`DSH_NO_LLM_MODE=1` skip the hook and use the plain proxy routing.

## 6. Verify

```bash
curl -s 127.0.0.1:1235/health                  # {"status":"ok","ais2_llm":true|false}
curl -s 127.0.0.1:1235/v1/models | head -c 300 # flash-next, ...-strix, AI Server 1 ids
ssh ai-server-2 llm-mode status                # "LLM mode on|off; model up|inactive; ..."
DSH_NO_LLM_MODE=1 dsh --version                # 0.1.5-rc.1
dsh "Reply with exactly one word: pong"        # in a terminal: "dsh: Flash-Next on AI Server 2 ready (N s)", then pong
grep -- '-> ais' ~/Library/Logs/dsh-mac-proxy.log | tail -3     # "-> ais2 flash-next"
```

The first `dsh` after the box was idle takes 2-10 min (job moves plus a ~30 s model load). Later ones start at once,
as long as the model is still loaded.

## Windows (TPC)

See below (filled from the TPC install).
