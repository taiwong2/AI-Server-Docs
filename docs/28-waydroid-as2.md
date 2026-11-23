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

**CMA blocks: solved 2026-11-13 12:49 CST (`kho=off`).** The ~13.2 GiB of migratetype-CMA pageblocks (counted in
MemAvailable, unusable by GTT/kernel allocations; `CmaTotal 0`, `/sys/kernel/mm/cma` empty) were the **Kexec HandOver
(KHO) scratch areas**: Ubuntu's 7.0 kernel has `CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT=y`, and KHO marks its scratch
memory MIGRATE_CMA. `/sys/kernel/debug/kho/out/scratch_len` listed 0x2f800000 + 0x210a00000 + 0x10be00000 = 13.2 GiB.
Fix: `kho=off` appended to `GRUB_CMDLINE_LINUX_DEFAULT` (backup `/etc/default/grub.bak-kho1113`), `update-grub`,
reboot. After it: `CmaFree 0`, MemAvailable 118.8 GB idle. KHO is only for live-update kexec, unused here. The
`usable = MemAvailable - CmaFree` formula in the floors/guards stays correct (CmaFree is now 0).
The reboot killed the 6 p100exit lanes (exit -15, marked failed, no auto-requeue); they were resubmitted with the same
env (resumable script) as 09148ba53f17 b13e33bcd9c8 1ee696cf8903 441fca705782 6fb8013340d7 35345ed98c29.

**Budget with LLM mode on (measured 11-13, before `kho=off`).** MemTotal 121.2 GiB - CMA 13.2 = ~108 GiB usable. gufo 97.7 at load +
up to ~6 GiB cache = ~103.5; kernel/services ~2. Left: **~2-3 GiB**. Waydroid (~3 GB RSS + GPU buffers) + ClashLLM
lean (~3.3 GB peak) need ~6-7 GB plus margin, so they do **not** fit beside the model once the prompt cache has filled.
The `coc up` floor (9 GB usable in LLM mode) refuses correctly (it did at 05:12). Options, the user's call: free the
CMA blocks (above); gufo `--cache-ram-bytes` 8 GiB -> 2 GiB (~4-5 GiB back); `--sessions 1` (halves the KV).
Without LLM mode: ~77 GiB usable with 6 p100exit lanes running.
**After `kho=off`:** ~121 GiB usable - gufo ~103.7 - ~2 = **~15 GiB left** with a full cache, enough for Waydroid +
ClashLLM (~6-7 GB) with margin; the 9 GB `coc up` floor now passes. To be confirmed live the next time LLM mode is on.

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

**Waydroid after the 11-13 reboot (fixed 12:00 CST).** `coc up` returned `NOT_STARTED adb`: `/var/lib/waydroid/waydroid.cfg`
named the binder nodes `binder`/`vndbinder`/`hwbinder`, but Waydroid allocates `anbox-*` nodes in binderfs at boot, so
LXC could not bind-mount `/dev/binder` and the 666 chmod hit a missing path. cfg now says `anbox-binder`,
`anbox-vndbinder`, `anbox-hwbinder` and `lxc/waydroid/config_nodes` mounts `/dev/anbox-*` onto `dev/{binder,...}`
(backups `~/waydroid-coach/*.bak-binder1113`). After changing either, `sudo systemctl restart waydroid-container`
(it prepares/chmods the drivers once per service start). A stale "Session RUNNING / Container STOPPED" needs
`wd.sh stop; sudo waydroid session stop` before `coc up` (wd-session stays active otherwise).

## 2026-11-16: updated to CoC 19.32.4 (13:45-13:56 CST)

- Found: Waydroid session + container **running** (not stopped), Clash 18.647.5 (versionCode 180647006) in the
  background, launcher on top; ClashLLM daemon active but PAUSEd by the user since 11-14 23:50.
- APK: APKMirror `com.supercell.clashofclans_19.32.4-190032005_minAPI24(arm64-v8a,armeabi-v7a,x86_64)(nodpi)`, a plain
  APK (not split/.apkm) with arm64-v8a, armeabi-v7a and x86_64 libs, sha256 `99b5441d…d210bb0`. On AS2:
  `~/apks/coc_19.32.4.apk`.
- Backup before install: `~/apks/backup_18.647.5/` (tar of `/data/data/com.supercell.clashofclans` from
  `~/.local/share/waydroid/data/data`, plus `dumpsys package` and `pm path`).
- Install: `adb -s 192.168.240.112:5555 install -r ~/apks/coc_19.32.4.apk` (streamed, ~13 s, in place; firstInstallTime
  stays 11-12). Result: versionName **19.32.4**, versionCode **190032005**, primaryCpuAbi **x86_64** (no native bridge),
  targetSdk 36.
- Launch: `monkey` fails (exit -5); use `am start -n com.supercell.clashofclans/com.supercell.titan.GameApp`.
  It shows the age gate, ToS notice, Usercentrics privacy dialog, then loads to a village. **No protector/Quago error.**
  Screenshots: Mac `~/Documents/ClashRuns/waydroid-coach/v19324_*.png` (`v19324_t_loaded.png` = village).
- Account: the village that loaded is a **fresh tutorial account (TH1, "Welcome Chief")**, not Grimwick47. This was
  not caused by the update: the pre-update backup already shows the app's prefs recreated at 08:36 CST today
  (`storage.xml` 402 bytes, Supercell ID plugin activity 09:22-09:28), i.e. the data had been cleared/reset before the
  update. To get Grimwick47 back: Settings -> Supercell ID (if it was linked), done by the user.
- Left: session/container running (as found), game in background, launcher on top, device lease released.

## Second instance (wd2, replay relay client; added 2026-11-22 CST)

A second, isolated Waydroid container for the ClashReplays session relay, next to the fleet's. Controller:
`ops/strixhalo/waydroid2/wd2.py` in ClashEngineering (server worktree `~/ce_replaywd`). **Off by default**; nothing of
it runs unless started. It never uses the fleet's resources:

| | fleet (untouched) | wd2 |
|---|---|---|
| LXC | `waydroid`, `/var/lib/waydroid/lxc` | `waydroid2`, `/var/lib/waydroid2/lxc` (cgroup `lxc.payload.waydroid2`) |
| binder | `anbox-*` | `/dev/binderfs/wd2-{binder,vndbinder,hwbinder}` |
| network | `waydroid0` 192.168.240.0/24 | `waydroid1` 192.168.241.0/24, own dnsmasq, iptables-legacy rules tagged `wd2` |
| weston | `wayland-wd` (wd-weston) | `wayland-wd2` (transient user unit `wd2-weston`, 512 MB / 50% CPU) |
| data | `~/.local/share/waydroid/data` | `~/.local/share/waydroid2/data` (fresh guest account, TH1 tutorial, no Supercell ID) |
| images | `/var/lib/waydroid/images` | same files, own read-only `noload` loop mounts |

Caps: cpu.max 3 cores, cpu.weight 20, memory.high 5G, memory.max 6G, no swap (peak seen 4.8 GiB with Clash loaded).
Guard: transient root unit `wd2-guard` stops wd2 when MemAvailable < 28.5 GB (above wd-ramguard's 25 GB floor and
far above as2-memguard's 2 GB shed point, so wd2 is always shed first; memguard's config is unchanged). `start`
refuses below 33 GB.

```
cd ~/ce_replaywd
sudo python3 ops/strixhalo/waydroid2/wd2.py start | stop | status
sudo python3 ops/strixhalo/waydroid2/wd2.py sh "am start -n com.supercell.clashofclans/com.supercell.titan.GameApp"
sudo python3 ops/strixhalo/waydroid2/wd2.py route-on | route-off   # DNAT tcp 9339 from waydroid1 only -> relay 127.0.0.1:19339
sudo python3 ops/strixhalo/waydroid2/wd2.py remove                 # stop + delete the wd2 binder devices
sudo rm -rf /var/lib/waydroid2 ~/.local/share/waydroid2            # then: delete instance + guest account
```
Screenshots: `wd2.py sh "screencap -p /data/local/tmp/s.png"`, then `sudo cat ~/.local/share/waydroid2/data/local/tmp/s.png`.
Relay flow and the sudo sampler: ClashReplays/LINUX_RUNTIME.md. 2026-11-22 18:22-18:35 CST: booted, Clash 19.32.4
loaded (hardware GL, no protector error), replay 12/12320423178 fetched; wd2 stopped afterwards.

**Continuous 19.32.4 collection (from 2026-11-22 19:35 CST).** wd2 is no longer left running: the driver boots it
only for a ~35 s login (caps memory.high 2G / max 3G / swap 2G: ~2.0 GB cgroup, 1.3 GB anon, vs 4.8 GB uncapped),
the relay then *detaches* the session (sends the game's keep-alives itself), and wd2 is stopped, so a fetching session
costs only the relay process (~35 MB for all workers). Logins wait for MemAvailable >= 32 GB (stop floor 28.5 GB +
3.5 GB). A root watchdog (`wd2-watchdog`) stops our containers on a fleet system_server pid change, the binder
"undelivered TRANSACTION_COMPLETE" signature or a fleet binder-error burst, and alerts `~/clashllm-data/alerts.jsonl`.
```
cd ~/ce_replayfetch && ops/strixhalo/waydroid2/replays19x.sh status | start | stop [all]
```
Data `~/ClashData/replays19x` (archive + extraction cursor, shard 12 ascending from 12320431703; driver.jsonl,
watchdog.jsonl). Details: ClashReplays/LINUX_RUNTIME.md ("Collector"). Never pause it without asking the user.

**Scale-up (2026-11-22 21:20-22:40 CST).** All sessions now pace at 0.25 s (the relay floor; 20 sessions = 66k, 36 = 114k
replays/h, 0 rate limits); the extraction cursor and archive index are WAL (`synchronous=NORMAL`) since the
FULL-fsync commit per ID had capped the total. The config lists 40 relay workers (ports 19339, 19361-19399); the
driver (`DRIVER_ARGS="--sessions N --make-guests"`) makes a fresh guest account in wd2 for any worker below N without
an account slot (age gate, ToS, privacy recognised from screencap pixels), so adding accounts is a driver restart,
not a serve restart. The serve unit is MemoryMax 2G / CPUQuota 200%; its relay cipher runs in numpy since 22:33
(it had become CPU-bound at ~36 sessions). Numbers per step: ClashReplays/LINUX_RUNTIME.md ("0.25 s and more accounts").

**Fleet incident seen during that window (not caused by wd2, not touched):** from 18:10 CST the fleet's adb
`screencap` timed out; at 18:24:35 the fleet daemon force-stopped its own Clash; at 18:26:17 its system_server was
killed by the Android watchdog (blocked in AMS / display) and has boot-looped every ~74 s since, main thread stuck
in `SurfaceControl.nativeGetCompositionDataspaces` (fleet SurfaceFlinger/hwcomposer hung). It kept looping after
wd2 was stopped (18:35). Recovery needs a fleet session restart, which is the fleet owner's call.
