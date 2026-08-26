---
name: ai-server-wake
description: Wake Tai's AI server when it is asleep, or work out why it is not sleeping. Use when the server does not answer ssh or ping, when a queued job has not started, when auto-sleep never triggers, or when testing Wake-on-LAN and wake timers safely.
---

# Waking the AI server

The box suspends to S3 when its queue is empty and nobody is using it. Not
answering is usually "asleep", not "broken".

## Is it asleep, or is something wrong?

```bash
ping 192.168.1.24
```

No answer means asleep or off. If it answers, it is awake and the problem is
elsewhere. Once awake:

```bash
python C:\AI-Server\scripts\jobqueue.py status
```

That names the gate holding it awake, or says it would sleep after the grace
period.

## Waking it

| From | How | Latency |
|---|---|---|
| The LAN (192.168.1.0/24) | `./wake-pc.sh` — magic packet | seconds |
| Anywhere | via the `wake-relay` tailnet node, which sits on the LAN | seconds |
| Anywhere, no relay | queue a job in the remote inbox; it wakes on its heartbeat | up to 20 min |

Target: MAC `04:7C:16:3E:B4:6E`, IP `192.168.1.24`, broadcast `192.168.1.255`
(the **subnet** broadcast — `255.255.255.255` is commonly dropped), UDP 9 and 7.

```bash
ssh <user>@100.127.179.9 './wake-pc.sh --send'    # via the relay
```

The relay only works while the relay itself is awake.

## Prove a magic packet arrives, without sleeping anything

"WoL is configured" and "the packet reaches this NIC" are different questions.
Test the second while the box is awake, where failure is free:

```bash
python C:\AI-Server\scripts\wol-listen.py --seconds 120   # server
./wake-pc.sh --send                                        # sender
```

The listener prints the target MAC and whether it matches this box, so a wrong
MAC, wrong broadcast, wrong subnet, or a broadcast-dropping switch is
immediately visible.

## Testing sleep safely

```powershell
powershell -File C:\AI-Server\scripts\wake-test.ps1           # arm
powershell -File C:\AI-Server\scripts\wake-test.ps1 -Report   # what woke it
powershell -File C:\AI-Server\scripts\wake-test.ps1 -Restore  # ALWAYS restore
```

Arming shortens the heartbeat to 3 minutes and lifts the busy-port guard, so the
box has two independent ways back. Wakes in seconds means WoL works. Returns on
its own in about 3 minutes means WoL did not, the timer did, and nothing is
stranded.

**Always `-Restore` afterwards.**

## Why it might never sleep

`status` will say. Common answers: a listening server on port 25565, a live GPU
lease, recent console input, a connected Sunshine stream, or the runner being
unable to arm a wake (not elevated — re-run `install-jobqueue.ps1` as
Administrator).

## Do not

- Do NOT call `SetSuspendState`, `shutdown`, or change power plans. Exactly one
  thing decides when this box sleeps: the queue runner.
- Do NOT disable the busy-port guard permanently — a listening game server means
  real people are connected.

Full reference: `docs/05-wake-and-power.md` in the ai-server-handbook repo.
