# TPC: the user's PC as a capped Clash fleet host

> **Status 2026-10-11: OFF at the user's request.** `attv3-infer` and `attv3-ractors` are stopped and disabled, Clash-SimKeepalive is ended and disabled, and `clash-sim` is terminated. To bring it back: `schtasks /change /tn Clash-SimKeepalive /enable`, `schtasks /run /tn Clash-SimKeepalive`, then in clash-sim as root `systemctl enable --now attv3-infer attv3-ractors`.


Added 2026-10-10 (fleet utilisation). TPC is the user's own Windows PC, so everything on it is **capped and low
priority**: it must stay usable for the user at all times.

| Item | Value |
|---|---|
| Hardware | Ryzen 7 3800X (8C/16T), 32 GB DDR4, RTX 5070 Ti 16 GB (Blackwell: torch needs cu128), C: ~46 GB free, D: 6.6 TB |
| Access | `ssh tpc` (user `tai`, tailnet 100.99.161.31, LAN 192.168.10.11, same LAN as AI Server 2). Keys: `C:\ProgramData\ssh\administrators_authorized_keys` (Mac key + AI Server 2's `ai-server_strix` key, added for the monitor; backup `.bak-20261010`). LAN port 22 is not reachable from AI Server 2; use the tailnet. Windows `python` is the Store stub: use `py` |
| WSL cap | `%USERPROFILE%\.wslconfig`: `memory=12GB`, `processors=12`, `swap=2GB` (was `memory=30GB`; backup `.wslconfig.bak-20261010`). It applies to every distro (also the user's `Ubuntu` and `docker-desktop`) |
| Distro | `clash-sim` (Ubuntu 24.04) at `D:\WSL\clash-sim`, runs as root with systemd. The user's `Ubuntu` stays the default distro and is never touched |
| Code | `/opt/clash/ce` = ClashEngineering, cloned from AI Server 2 over the LAN (`taiwong@192.168.10.9:ClashEngineering`; key `/root/.ssh/id_ed25519`, accepted on AI Server 2 only `from="192.168.10.11,100.99.161.31"`). No GitHub credentials on the PC |
| Engine data | `/opt/clash/ce/{artifacts,extracted/lib/x86_64,.toolchain}` rsynced from AI Server 2 (same subset as AI Server 1 clash-sim, ~1.5 GB) |
| Python | PIE CPython `/opt/clash/python3.12-pie` (`tools/x86_pie_python.sh`) + venv `/opt/clash/attv3_cuda` (torch 2.11+cu128) |
| Actor key | `/etc/clash/actor_key` (root 600, same value as AI Server 1 `C:\WSL\actor_key`) |

## Units (ClashEngineering `ops/tpc/install_units.sh [PROCS] [ENVS]`)

| Unit | What | Limits |
|---|---|---|
| `attv3-infer` | CA-4 shared inference server on the 5070 Ti (`/run/clash/attv3_infer.sock`) | Nice 10, CPUWeight 50, MemoryMax 3G |
| `attv3-ractors` | CA-4 remote actors, `--connect 192.168.10.9:8895` **direct over the LAN** (WSL NAT reaches AI Server 2; no relay, unlike AI Server 1), `CLASHLAB_ACTOR_HOST=TPC` (the hub logs "remote N from TPC") | Nice 10, CPUWeight 50, MemoryMax 8G; default 2 procs x 3 envs (~3.4 GB RSS per proc) |

Update code: `wsl -d clash-sim -u root -- /opt/clash/units/update.sh [REF]` (fetches AI Server 2's branches as `as2/*`,
default REF `as2/main`, checks out REF, restarts both units). The engine data also needs `extracted/lib/arm64-v8a`
(read by tools/native_battle_probe.py since 668ead8; rsynced from AI Server 2).

## Persistence

Scheduled task **Clash-SimKeepalive** (S4U, user tai, at startup + at logon, restarts every minute on failure) holds
`wsl.exe -d clash-sim -u root -- /bin/sleep infinity`, so the distro (and its enabled systemd units) stays up
without a console window. Stop everything: `schtasks /end /tn Clash-SimKeepalive` then `wsl -t clash-sim`.
Disable: `schtasks /change /tn Clash-SimKeepalive /disable`. No power or sleep settings were changed.

## Monitoring

The ClashLab monitor on AI Server 2 polls TPC every pass (`ssh tpc py -`, `clashlab.monitor_probe.winbox`): Windows
CPU / memory, the clash-sim distro's CPU / memory, the 5070 Ti. It shows as the TPC tiles of the Overview's fleet
row. An unreachable PC keeps its last snapshot with its age.
