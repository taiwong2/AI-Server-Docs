# 28. Waydroid on AI Server 2 (live Clash client for coaching)

Set up 2026-11-11/12 (CST). Purpose: run the official Clash of Clans client headless on AI Server 2 so a coaching /
upgrade-suggestion tool can take screenshots and send taps, and so the user can play on it remotely.

## Result

- The official client **18.647.5** (Supercell signing cert SHA-256 `9ea146d9…`, same as the Play build) runs under
  Waydroid on AS2 with **no anti-tamper (Quago) error**: through first launch, the age gate, the full tutorial
  (including the tutorial attack) and a relaunch.
- Waydroid used its **stock device identity** (`WayDroid x86_64 Device`, userdebug/test-keys). No build props were
  changed, nothing was patched, no root hiding.
- Why it works where redroid / AVDs / Cuttlefish failed on AS2 (protector codes 02/16): best explanation is that
  18.647.5 ships **x86_64 native libraries**, so no ARM translation (libndk/houdini) is involved. The old 18.647.2 APK
  only showed "Update is available!" (needs Play Store), so 18.647.5 was taken from APKMirror.
- Account created on it: **Grimwick47** (TH2, tutorial done, age 21, no Supercell ID / email linked, nothing bought).
  It exists only on this install until the user links it to their Supercell ID (Settings → Supercell ID).
  Supercell ID also gives in-game account switching between the user's accounts.

## Layout on AS2

| What | Where |
|---|---|
| Control script | `~/waydroid-coach/wd.sh start\|stop\|status\|shot OUT.png` |
| RAM guard | `~/waydroid-coach/ramguard.sh` (user unit `wd-ramguard`): stops the session when MemAvailable < 25 GB, to protect research jobs |
| User units (not enabled at boot) | `~/.config/systemd/user/wd-weston.service` (headless weston), `wd-session.service`, `wd-ramguard.service` |
| APKs | `~/waydroid-coach/coc_18.647.5.apk`, `com.supercell.clashofclans_18.647.2.apk` (outdated) |
| Images / data | `/var/lib/waydroid` (LineageOS 20 GAPPS), `~/.local/share/waydroid` (Android data, incl. the account) |
| Container limits | appended to `/var/lib/waydroid/lxc/waydroid/config`: 4 cores, 6 GB RAM, no swap (original: `~/waydroid-coach/lxc_config.orig`) |
| Kernel module | `binder_linux`, loaded at boot via `/etc/modules-load.d/waydroid-binder.conf` |
| Install record | `~/waydroid-coach/dpkg_before.txt` / `dpkg_after.txt`, `getprop_stock.txt`, `shots/` |
| Screenshots on Mac | `~/Documents/ClashRuns/waydroid-coach/` (`v5stock_t60_agegate.png`, `new_account_done.png`, …) |

Packages: waydroid 1.6.3 (repo `/etc/apt/sources.list.d/waydroid.list`, key `/usr/share/keyrings/waydroid.gpg`),
weston, lxc + deps. `waydroid-container.service` (system) is installed by the package. `pipewire-pulse.socket` must be
running (Waydroid will not start without an audio socket); `wd.sh start` covers the rest.

## Use

```
# on AS2
~/waydroid-coach/wd.sh start      # weston + session + guard, unfreezes, launches Clash
~/waydroid-coach/wd.sh status
~/waydroid-coach/wd.sh shot out.png
~/waydroid-coach/wd.sh stop
adb -s 192.168.240.112:5555 ...   # container adb (AS2 key authorised)

# from the Mac (adb key authorised)
ssh -f -N -L 15555:192.168.240.112:5555 ai-server-2
~/Library/Android/sdk/platform-tools/adb connect localhost:15555
scrcpy -s localhost:15555         # brew install scrcpy; view + play
```

Screen is 1600x900 landscape. If the screen stops updating the container is frozen: `wd.sh start` unfreezes it. If the
game vanished, the RAM guard probably stopped the session (research jobs use most of AS2's RAM): `wd.sh start` again.
Resource use at idle: ~0.3 core, ~1.1 GB app RAM (4.7 GB with cache, peak 5.7 GB), weston ~90 MB; disk ~3 GB images +
1.7 GB data.

## Status

Stopped 2026-11-12 (CST) at the user's request (`wd.sh stop`, `waydroid session stop`, `waydroid-container` stopped).
Everything stays installed; `wd.sh start` brings it back with the account intact.

## Remove completely

```
~/waydroid-coach/wd.sh stop; sudo waydroid session stop; sudo systemctl disable --now waydroid-container
sudo apt purge waydroid weston lxc   # plus the deps in diff dpkg_before.txt dpkg_after.txt
sudo rm /etc/apt/sources.list.d/waydroid.list /usr/share/keyrings/waydroid.gpg /etc/modules-load.d/waydroid-binder.conf
sudo rm -rf /var/lib/waydroid; rm -rf ~/.local/share/waydroid ~/waydroid-coach
rm ~/.config/systemd/user/wd-{weston,session,ramguard}.service
```
Removing `~/.local/share/waydroid` deletes Grimwick47 unless it was linked to a Supercell ID first.

## Rules

Research jobs on AS2 have priority: keep the cgroup caps and the RAM guard. Do not patch the game or hook its
protector. Never log into accounts on the user's behalf; the user signs in / links Supercell ID.

## LLM player (from 2026-11-12 14:00 CST)

The user gave Grimwick47 to an LLM to play everything except battles (upgrades, building, layouts, clan/war management).
- Control CLI on AS2: `~/waydroid-coach/coc up|busy|shot|tap|hold|swipe|drag|text|back|home|zoomout`.
- Player: aq task `coc-player` (Sonnet, every 2 h, <= ~25 min per session), prompt
  `~/.claude/agent-queue/prompts/coc/player.md`; memory = `~/waydroid-coach/llm-player/journal.md` (+ `shots/`).
- It never acts while the user is connected with scrcpy, or while `~/waydroid-coach/llm-player/PAUSE` exists
  (`touch` to pause, `rm` to resume). It stops Waydroid after each session to give RAM back to research, and does not
  start when host MemAvailable < 30 GB.
- Stop for good: `aq cancel <coc-player id>`.

## ClashLLM (from 2026-11-12 evening; replaces the Sonnet pixel player)

ClashLLM (`clashllm/` in ClashEngineering) lets a small model (Claude Haiku via the Anthropic API by default) play
Grimwick47: compact JSON state + numbered menu in, one-line reply out, every action executed and verified by code.
Full runbook: `clashllm/README.md` in the repo.
- Code: server worktree `~/ce_clashllm`, venv `~/clashllm-venv`, data `~/clashllm-data/accounts/grimwick47/`
  (journal, shots, schedule.txt). API key: `~/.config/clashllm/anthropic_key` (chmod 600).
- One session: `cd ~/ce_clashllm && ~/clashllm-venv/bin/python -m clashllm play --backend anthropic --max-steps 20`.
- **Switched ON 2026-11-12 evening (user's request): unattended play + multiplayer farming.** The systemd user unit
  `clashllm-daemon` is enabled (lingering on, survives logout/reboot). Each wake: PAUSE/scrcpy check -> Sonnet
  commander if its directive is > 24 h old -> `coc up` (refused below the RAM floor: retry in 20 min) -> Haiku
  session (<= 40 steps, <= 45 min: collect, build from the plan, farm when the next upgrade needs loot, train) ->
  schedule.txt/json + status.json -> Waydroid stopped (under the device lease) when the next wake is > 20 min away.
- Report: `cd ~/ce_clashllm && ~/clashllm-venv/bin/python -m clashllm report` (last 24 h: sessions, upgrades,
  attacks, stars, loot, gems spent, errors, next wake; `--hours N`, `--json`). Next wake:
  `cat ~/clashllm-data/accounts/grimwick47/schedule.txt`. Log: `journalctl --user -u clashllm-daemon -f`.
- **Pause** (daemon keeps running, touches nothing): `touch ~/clashllm-data/PAUSE`; resume: `rm ~/clashllm-data/PAUSE`.
  The old `~/waydroid-coach/llm-player/PAUSE` also works; scrcpy attached = hands off (retry in 10 min).
- **Stop**: `systemctl --user stop clashllm-daemon`; keep it off after reboot: `systemctl --user disable --now
  clashllm-daemon`; on again: `systemctl --user enable --now clashllm-daemon`. Waydroid: `~/waydroid-coach/wd.sh stop`.
- Attack switch `~/clashllm-data/ATTACK` (or `$CLASHLLM_ATTACK`): `off` | `single` (goblin maps) | `multi`
  (multiplayer farming; set 11-12). Anything else is off. `echo off > ~/clashllm-data/ATTACK` stops attacks only.
- One driver at a time through the device lease (`coc lease STATUS`); hold it (`coc lease ACQ me`) to do manual work.

## 2026-11-13 thrash hang and the memory guard

**What happened (05:15-11:06 CST, power cycle at 11:09).** LLM mode went on at 03:19; gufo loaded at 03:25 with
`gpu_device_used_mib=100065` (97.7 GiB GTT; docs/17 measured 90.8 GiB with a smaller cache) and the 2-session prompt
cache added ~6 GiB of GTT snapshots under heavy dsh use (123k-token prompts until 05:13). The kernel OOM reports show
`gpu_active` 106-107 GiB. Waydroid + ClashLLM were started beside it at 05:01 (daemon; the floor then still used plain
MemAvailable) and 05:13 (manual). Global OOMs at 05:02 (clashllm-daemon), 05:27, 05:52, 07:09 and 10:40 picked small
processes (Waydroid apps, baseimg) while the 8 GB swap file was full and kswapd thrashed; sshd could not finish a
banner for hours. Userspace anon at the 05:27 OOM was only 3.4 GB. The GPU memory is not killable (gufo -900).

**CMA mystery.** ~13.2 GiB of pageblocks are migratetype CMA (`/proc/pagetypeinfo` CMA column 6372 Normal + 380 DMA32
blocks, `/proc/zoneinfo` cma 3,457,024 pages) although the boot log says `0K cma-reserved`, `/sys/kernel/mm/cma` is
empty and the cmdline has no `cma=` (kernel 7.0.0-43, CONFIG_CMA_SIZE_MBYTES=0, CONFIG_DMA_CMA/DMA_NUMA_CMA=y). These
pages count in MemAvailable but GTT (TTM, non-movable) and kernel allocations cannot use them; at the 05:27 OOM 10 GB
of `free_cma` sat unused. So **usable = MemAvailable - CmaFree** everywhere (coc floors, ramguard, memguard).
Proposed (not applied, needs a reboot and the user): find the owner first (`echo 1 > /sys/kernel/mm/page_owner` needs
`page_owner=on` on the cmdline; or try a boot with `cma=0` and compare `/proc/pagetypeinfo`). Getting those 13 GiB
back is the one change that would make Waydroid + ClashLLM fit beside a full-cache gufo without touching gufo.

**Budget with LLM mode on (measured 11-13).** MemTotal 121.2 GiB - CMA 13.2 = ~108 GiB usable. gufo 97.7 at load +
up to ~6 GiB cache = ~103.5; kernel/services ~2. Left: **~2-3 GiB**. Waydroid (~3 GB RSS + GPU buffers) + ClashLLM
lean (~3.3 GB peak) need ~6-7 GB plus margin, so they do **not** fit beside the model once the prompt cache has filled.
The `coc up` floor (9 GB usable in LLM mode) refuses correctly (it did at 05:12). Options, the user's call: free the
CMA blocks (above); gufo `--cache-ram-bytes` 8 GiB -> 2 GiB (~4-5 GiB back); `--sessions 1` (halves the KV).
Without LLM mode: ~77 GiB usable with 6 p100exit lanes running.

**Deployed levers (ops/strixhalo/memguard/, `sudo sh ~/ClashEngineering/ops/strixhalo/memguard/install.sh`):**
- `as2-memguard.service` (root, mlockall, every 2 s): warn at usable < 4 GB / PSI some > 40; shed `wd-session`,
  `clashllm-daemon`, `wd-weston` at usable < 2 GB, PSI full > 20, or swap almost full with usable < 4 GB; at usable < 1 GB
  or PSI full > 50 SIGKILL the biggest process with oom_score_adj >= 500 (Waydroid apps 905, ClashLLM 1000). Never
  clashjobs (200), gufo (-900), sshd (-1000), tailscaled (-950). Overrides: `/etc/ai-server-2/memguard.json`. Log:
  `journalctl -u as2-memguard`, `/var/log/as2-memguard.log`.
- `zram-as2.service`: 8G zstd zram at priority 100 ahead of the 8G swap file.
- ssh.service `MemoryMin=256M` (no OOMScoreAdjust: sshd sets itself to -1000 and hands the unit value to sessions),
  tailscaled `OOMScoreAdjust=-950 MemoryMin=256M`.
- `llm-mode` stops `clashlab-baseimg` while the model is resident (llm_lanes.json `pause_units`).
- A flag that outlives a reboot no longer sticks: the idle watcher turns LLM mode off when the model is gone
  (llm-gufo not running, no `on` in flight), and keepers starts a fresh watcher with systemd-run (its old `restart`
  of the transient unit returned 5 for an hour after the power cycle).
