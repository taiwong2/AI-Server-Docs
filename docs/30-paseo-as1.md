# 30. Paseo on AI Server 1 (agent orchestration + iPhone app)

Set up 2026-11-22. Paseo (https://paseo.sh, github.com/getpaseo/paseo) is a daemon that runs coding agents
(OpenCode on Strata, Claude Code, Codex, Antigravity) and lets you drive them from the Paseo iPhone app, a browser, or the `paseo` CLI.
Agents launched by Paseo get Paseo's own tools (`paseo_create_agent`, `paseo_send_agent_prompt`,
`paseo_get_agent_status`, `paseo_get_agent_activity`, ...) so one agent can start and talk to others.
The local agent is OpenCode on Strata (the AS1 LLM, see the Strata doc).

## What runs

| Piece | Version | Where |
|---|---|---|
| Node.js (user-local, not apt) | v24.22.3 | `~/.local/opt/node` (symlink to `node-v24.22.3-linux-x64`) |
| npm global prefix | | `~/.local/npm-global` (bins in `~/.local/npm-global/bin`) |
| Paseo CLI + daemon | `@getpaseo/cli` 0.17.3 | systemd **user** unit `paseo.service` |
| OpenCode | `opencode-ai` 1.19.6 | launched by Paseo as `opencode serve --port <random>` |
| Claude Code | `@anthropic-ai/claude-code` 2.1.330 | provider, logged in 2026-11-22 (`claude auth login`) |
| Codex CLI | `@openai/codex` 0.171.0 | provider, logged in 2026-11-22 (ChatGPT login copied from the wake relay, see below) |
| Antigravity CLI (`agy`) | 1.5.14 (Google's installer, not npm) | `~/.local/bin/agy`, provider `antigravity`, Google login 2026-11-22 |
| Gemini CLI | `@google/gemini-cli` 0.70.0 | installed but NOT a provider (Google ended its personal sign-in, see below) |
| gh | 2.46.0 (apt) | not logged in (only needed for PR-aware worktrees) |

Providers as of 2026-11-22 20:20 CST (`paseo provider ls`): claude, codex, opencode, antigravity all `available`;
copilot, pi, muse etc. are Paseo's built-in defaults (not installed, ignore them).

The PATH line at the top of `~/.bashrc` (marked `paseo-as1`) adds node and the npm globals, also for
non-interactive `ssh ai-server-1 <cmd>`. Backup of the previous file: `~/.bashrc.bak-paseo`.

Footprint: ~1.1 GB RAM for the daemon (it includes a local dictation model, parakeet 0.6B int8, in
`~/.paseo/models`), plus ~0.4 GB per OpenCode server. The unit caps it at `MemoryHigh=3G`, `MemoryMax=6G`, `Nice=5`.
It never touches the GPUs; all inference goes to Strata over HTTP.

## Start / stop / status / logs

```
systemctl --user status paseo
systemctl --user restart paseo          # full restart (also needed after changing daemon.listen / auth)
systemctl --user stop paseo             # stop; `disable` to keep it off after reboot
paseo daemon status                     # endpoint, providers, relay
paseo reload                            # apply runtime-safe config.json edits
journalctl --user -u paseo -f           # console log
tail -f ~/.paseo/daemon.log             # file log (rotates 10 MB x 3)
```

Lingering is on for poopl, so the unit starts at boot without a login. The daemon binds the Tailscale IP; if
tailscaled is not up yet at boot, the bind fails and systemd retries every 10 s (`Restart=always`).

Do not use `paseo daemon start/stop` for this install: the systemd unit runs `paseo daemon run` (foreground),
and a second, unmanaged supervisor would fight it.

## Update

```
npm i -g --allow-scripts=@anthropic-ai/claude-code,opencode-ai,esbuild,node-pty,msgpackr-extract \
  @getpaseo/cli@<ver> opencode-ai@<ver> @anthropic-ai/claude-code@<ver> @openai/codex@<ver>
curl -fsSL https://antigravity.google/cli/install.sh | bash      # agy (Paseo needs >= 1.5.0)
systemctl --user restart paseo
```

`--allow-scripts` is needed: npm 11 blocks install scripts by default and node-pty / opencode need theirs.
Pin exact versions (check `npm view <pkg> version`). OpenCode has `"autoupdate": false`.

## Config paths (all 0600 where secrets are involved)

| File | What |
|---|---|
| `~/.config/systemd/user/paseo.service` | the unit (`EnvironmentFile=~/.config/paseo-as1/strata.env`, `WorkingDirectory=~/paseo-work`) |
| `~/.paseo/config.json` | Paseo config (below) |
| `~/.paseo/daemon-keypair.json` | daemon identity for relay pairing; deleting it invalidates paired phones |
| `~/.config/opencode/opencode.json` | OpenCode provider config (below) |
| `~/.config/paseo-as1/strata.key`, `strata.env` | Strata API key (raw / `STRATA_API_KEY=`), 0600, never in git |
| `~/paseo-work/` | default working dir for agents; `scratch/` is a test dir |

`~/.paseo/config.json`:

```json
{
  "version": 1,
  "daemon": {
    "listen": "100.70.25.10:6767",
    "mcp": { "enabled": true, "injectIntoAgents": true },
    "relay": { "enabled": true }
  },
  "features": { "webUi": { "enabled": true } },
  "agents": {
    "idleRuntimeCleanup": true,
    "providers": {
      "opencode":    { "paseoTools": { "enabled": true } },
      "codex":       { "enabled": true, "paseoTools": { "enabled": true } },
      "antigravity": { "env": { "SSH_CONNECTION": "paseo" }, "paseoTools": { "enabled": true } }
    }
  },
  "log": { "...": "console info, file ~/.paseo/daemon.log info, rotate 10m x 3" }
}
```

To limit what a provider's agents may do with Paseo tools, add per-provider
`"paseoTools": {"disabledTools": ["kill_agent", ...]}` (custom provider IDs do not inherit it), then
`paseo reload` and start a new agent. This is not a security boundary: agents also have a shell.

## OpenCode provider (Strata)

`~/.config/opencode/opencode.json` defines provider `strata` with `@ai-sdk/openai-compatible`:

- `baseURL`: `http://100.70.25.10:8080/v1` (`strata-proxy` on the Tailscale IP; Strata loads on demand, so the first prompt after 30 idle minutes waits about 22 s)
- `apiKey`: `{file:~/.config/paseo-as1/strata.key}`
- model `orcarouter-qwen3.8-flash-next-uncensored-iq3_xxs` (the id from `/v1/models`), `tool_call`, `attachment`,
  `reasoning` true, text+image input, `limit.context` 262144 (Strata serves 1M; kept lower for speed),
  `limit.output` 32768
- default `model` and `small_model` both point at it; `share: disabled`, `autoupdate: false`

In Paseo pick provider **OpenCode** and model `strata/orcarouter-qwen3.8-flash-next-uncensored-iq3_xxs`
(CLI: `--provider opencode/strata/orcarouter-qwen3.8-flash-next-uncensored-iq3_xxs`). OpenCode also lists its
own free cloud models; ignore those.

Quick checks:
```
cd ~/paseo-work/scratch && opencode run "Use your read tool to read note.txt and print it"
paseo provider diagnostic opencode
```

## Phone (Paseo iPhone app)

Two ways in, both set up:

1. **Relay (works anywhere, no Tailscale on the phone).** End-to-end encrypted through relay.paseo.sh. On AS1:
   `paseo daemon pair` prints a QR code and a link (`https://app.paseo.sh/#offer=...`). In the app scan the QR or use
   **Paste pairing link**. From the Mac: `ssh -t ai-server-1 paseo daemon pair`. The offer is static (server id +
   daemon public key), so it does not expire, but treat the link as a secret: whoever has it can connect.
2. **Direct over the tailnet.** Phone on Tailscale, then in the app **Settings -> Add host -> Direct connection**,
   Host `100.70.25.10`, Port `6767`, SSL off. Same host as the relay pairing, it just adds a route.

Web UI from any tailnet device: http://100.70.25.10:6767/ . Remote CLI from the Mac (with paseo installed):
`paseo --host ssh://ai-server-1 ls -a` does not work as is (the daemon is not on 127.0.0.1); use
`paseo --host 100.70.25.10:6767 ls -a`.

No daemon password is set: the daemon listens only on the Tailscale IP. To add one: `paseo daemon set-password`,
then `systemctl --user restart paseo`, and enter it in the app.

## One-time logins for the other providers

All done on 2026-11-22. To redo one:

```
ssh -t ai-server-1 claude auth login        # Claude subscription; opens a URL, paste the code back
ssh -t ai-server-1 codex login --device-auth
ssh -t ai-server-1 'SSH_CONNECTION=1 ~/.local/bin/agy'   # Antigravity: choose Google OAuth, paste the code, then /logout to switch accounts
```

Then `paseo provider diagnostic claude` / `codex` / `antigravity`. gh only if PR-aware worktrees are wanted:
`ssh -t ai-server-1 gh auth login`.

Without a terminal (as on 11-22), run the login inside tmux on AS1 and read the URL with `tmux capture-pane -p -J`;
paste the browser's code back with `tmux send-keys`. Google codes expire quickly (Gemini CLI waited 5 min).

**Codex:** the 11-22 login was not made on AS1: `~/.codex/auth.json` was copied from the wake relay Mac mini
(`root@100.127.179.9`, user `yichunyan`, the user's own ChatGPT login; user OK 11-22), mode 0600. `codex login status`
says "Logged in using ChatGPT". If it expires, run the device login above instead.

**Antigravity:** installed with `curl -fsSL https://antigravity.google/cli/install.sh | bash` (binary only, no
sudo; update the same way). The daemon has no desktop keyring, so agy uses its SSH-mode token file
`~/.gemini/antigravity-cli/antigravity-oauth-token` (0600): the login above runs with `SSH_CONNECTION=1`, and the
Paseo provider sets `"env": {"SSH_CONNECTION": "paseo"}` so the daemon reads the same file. Models via the
Google account (`SSH_CONNECTION=1 agy models`): gemini-3.8-flash high/medium/low, claude-sonnet-4-6,
claude-opus-4-6-thinking, gpt-oss-120b-medium. Smoke test 11-22: `paseo run --provider
antigravity/gemini-3.8-flash-low "Reply with exactly: pong"` -> pong.

**Gemini CLI: not usable with a Google login.** On 11-22 the Google sign-in was refused by Google: "This client is
no longer supported for Gemini Code Assist for individuals. ... migrate to the Antigravity suite". The `gemini`
provider was removed from the Paseo config. The CLI would still work with a Gemini API key; one was pasted on 11-22
and sits in `~/.gemini/.env` (0600) unused. Gemini CLI also does not read that file from an untrusted folder.

## Orchestration test (2026-11-22)

`paseo run --provider opencode/strata/... "<use paseo_create_agent / paseo_send_agent_prompt / paseo_get_agent_status /
paseo_get_agent_activity ...>"`: the OpenCode agent on Strata started a second OpenCode agent, sent it "17 x 23",
polled it to idle and read back `391`. Working, with caveats about the local model:

- When the prompt said `create_agent` (the name in Paseo's docs), the model invented tool names
  (`mcp__webui_bff__create_agent`) and printed a raw `<tool_call>` as text instead of calling. Paseo exposes the tools
  to OpenCode as `paseo_<name>`; prompts that use those exact names work.
- `paseo_create_agent` took 3 schema errors before it got the arguments right (`provider` as `provider/model`,
  `initialPrompt`, `workspace: {kind: "current"}`, `relationship: {kind: "subagent"}`); it recovered on its own from
  the error messages.
- The tool catalog is ~56 tools; if the small model keeps confusing them, trim it with `paseoTools.disabledTools`.

## Troubleshooting

- `paseo` not found over ssh: the PATH line must be the first lines of `~/.bashrc` (before the interactive check).
- Phone "connection timed out" on direct: Tailscale off on the phone, or the daemon did not bind (check
  `ss -ltn | grep 6767`, `journalctl --user -u paseo`).
- OpenCode agent errors with 401: the key file changed; rewrite `~/.config/paseo-as1/strata.key` and `strata.env`
  from Strata's config, 0600.
- Strata is loaded on demand by `strata-proxy` (docs/24, "On demand"): an agent prompt after an idle period waits ~22 s for the load. An error `strata_unavailable` (HTTP 503) means the GPUs are taken by a training job; `strata-mode status` on AS1 shows who holds them.
- Config change ignored: `paseo reload`; if it says restart-required, `systemctl --user restart paseo`.
- Remove everything: `systemctl --user disable --now paseo`, `rm ~/.config/systemd/user/paseo.service`,
  `npm rm -g @getpaseo/cli opencode-ai @anthropic-ai/claude-code @openai/codex`, `rm -rf ~/.paseo`,
  drop the `paseo-as1` lines from `~/.bashrc`.
