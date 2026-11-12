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
