# Bitwarden vault (credentials for agents)

The user's Bitwarden account (taiwong263@gmail.com, US cloud: vault.bitwarden.com) is the place for credentials that
agents need. The vault lives in Bitwarden's cloud, so reinstalling a machine loses only that machine's CLI login.

## Where the CLI is logged in

| Machine | CLI | Login state |
|---|---|---|
| AI Server 1 (Linux, `ssh ai-server-1`) | `~/.local/bin/bw` 2026.11.0 (`bw-bit-linux` from github.com/bitwarden/clients) | logged in 2026-11-22 (new-device email code approved by the user) |
| AI Server 1 (old Windows) | winget `Bitwarden.CLI`, `C:\AI-Server\scripts\bw-session.ps1` | gone with the 2026-11-22 Linux reinstall |

Master password: `~/.config/credentials/bitwarden-master.txt` on AI Server 1 (dir 700, file 600, poopl only).
Restored from the Windows backup (`/mnt/mybook/AS1-Backup-20261122/files/C/AI-Server/state/credentials/
bitwarden-master.txt`). That copy has a UTF-8 BOM; strip it or `bw` reports "Invalid master password". Never print,
log or commit it.

## Use (headless)

```
ssh ai-server-1
export BW_SESSION=$(bw-session </dev/null)     # ~/.local/bin/bw-session: bw unlock --passwordfile ... --raw
bw sync
bw list items --search "<name>"
bw get password "<item name or id>"
bw lock                                        # always lock when done
```

Run `bw` with `</dev/null` (or a timeout) from scripts: without a session or with a wrong password it waits for
interactive input forever.

A login on a new machine asks for a one-time code that Bitwarden emails to the account ("new device verification").
Every new `bw login` attempt sends a fresh code and invalidates the previous one, so start one login (e.g. inside
tmux), wait for the user's code, and type it into that same prompt.

## Contents (2026-11-22)

| Item | Type | Notes |
|---|---|---|
| Hugging Face token (vusto) | login (user `vusto`, password = HF read token) | gated model downloads (Strata / OrcaRouter Flash-Next Uncensored). The user plans to rotate it: update this item and AI Server 1 `~/.cache/huggingface/token` (mode 600) together |

The vault was empty before that (it was set up 2026-08-09 but never filled). Add new service credentials here instead of
loose files on the servers.
