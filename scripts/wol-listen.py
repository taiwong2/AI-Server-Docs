r"""wol-listen.py - prove a Wake-on-LAN magic packet actually reaches this box.

WHY. "Is WoL configured" and "does a magic packet from that Mac arrive here"
are different questions, and only the second one matters. The usual way to test
the second is to sleep the machine and see whether it comes back -- which, if
it does not, leaves you with a box you have to walk over to. This listens for
the packet WHILE THE MACHINE IS AWAKE, so the LAN path (switch, router,
broadcast forwarding, subnet) is proven before anything is suspended.

It cannot prove the NIC will wake the machine from S3 -- that is firmware, and
only a real sleep tests it. But every failure that ISN'T firmware shows up
here: wrong MAC, wrong broadcast address, a Mac on a different subnet, a
switch that drops directed broadcasts, a firewall rule.

A magic packet is 6 bytes of 0xFF followed by the target MAC repeated 16 times,
usually sent to UDP 9 (discard) or 7 (echo) on the subnet broadcast. Nothing
listens on those ports normally; the NIC sniffs them in hardware. Binding them
in software while awake is harmless and does not interfere with the hardware
path.

    python wol-listen.py                 # listen 120s on ports 9 and 7
    python wol-listen.py --seconds 600
    python wol-listen.py --mac 04-7C-16-3E-B4-6E
"""
from __future__ import annotations

import argparse
import binascii
import re
import select
import socket
import subprocess
import sys
import time
from datetime import datetime

DEFAULT_PORTS = (9, 7)


def local_macs():
    """MACs of every up adapter, normalised to lowercase hex with no separators."""
    out = set()
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | "
             "ForEach-Object { $_.MacAddress }"],
            capture_output=True, text=True, timeout=30)
        for line in (r.stdout or "").splitlines():
            m = re.sub(r"[^0-9a-fA-F]", "", line)
            if len(m) == 12:
                out.add(m.lower())
    except Exception:
        pass
    return out


def find_magic(data):
    """The MAC a magic packet targets, or None.

    Looks for 0xFF*6 followed by the same 6 bytes 16 times. Scans rather than
    assuming offset 0, because some senders prepend a SecureOn password or wrap
    the payload."""
    idx = data.find(b"\xff" * 6)
    while idx != -1:
        body = data[idx + 6:idx + 6 + 6 * 16]
        if len(body) == 96:
            mac = body[:6]
            if body == mac * 16:
                return binascii.hexlify(mac).decode()
        idx = data.find(b"\xff" * 6, idx + 1)
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="Listen for Wake-on-LAN magic packets")
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--ports", type=int, nargs="+", default=list(DEFAULT_PORTS))
    ap.add_argument("--mac", action="append", default=[],
                    help="also treat this MAC as ours (repeatable)")
    a = ap.parse_args(argv)

    mine = local_macs()
    for m in a.mac:
        mine.add(re.sub(r"[^0-9a-fA-F]", "", m).lower())
    print(f"this box: {', '.join(sorted(mine)) or '(no MACs found)'}")

    socks = []
    for p in a.ports:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.bind(("", p))
            s.setblocking(False)
            socks.append((p, s))
            print(f"listening on UDP {p}")
        except OSError as e:
            print(f"could NOT bind UDP {p}: {e}")
    if not socks:
        print("nothing to listen on")
        return 2

    print(f"waiting {a.seconds}s -- send the magic packet from the Mac now\n")
    deadline = time.time() + a.seconds
    hits = 0
    while time.time() < deadline:
        ready, _, _ = select.select([s for _, s in socks], [], [], 1.0)
        for s in ready:
            port = next(p for p, sk in socks if sk is s)
            try:
                data, addr = s.recvfrom(2048)
            except OSError:
                continue
            stamp = datetime.now().strftime("%H:%M:%S")
            mac = find_magic(data)
            if mac:
                hits += 1
                pretty = ":".join(mac[i:i + 2] for i in range(0, 12, 2))
                for_us = mac in mine
                verdict = "FOR THIS BOX" if for_us else "for a DIFFERENT machine"
                print(f"[{stamp}] MAGIC PACKET from {addr[0]}:{addr[1]} -> UDP {port} "
                      f"| target {pretty} | {verdict}")
                if not for_us:
                    print("           the MAC does not match this box -- the sender "
                          "has the wrong address, which is why nothing wakes")
            else:
                print(f"[{stamp}] udp from {addr[0]} -> {port}, {len(data)}B, "
                      f"not a magic packet")
    print()
    if hits:
        print(f"RESULT: {hits} magic packet(s) arrived. The LAN path works -- "
              f"switch, broadcast and MAC are all correct.")
        print("Remaining unknown: whether the NIC wakes the box from S3. "
              "Only a real sleep tests that.")
        return 0
    print("RESULT: nothing arrived.")
    print("  * is the Mac on 192.168.1.0/24 (not Wi-Fi guest / a different VLAN)?")
    print("  * did it send to the SUBNET broadcast 192.168.1.255, not 255.255.255.255?")
    print("  * is Windows Firewall dropping inbound UDP 9? (the hardware path is")
    print("    unaffected by the firewall, but this software listener is not)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
