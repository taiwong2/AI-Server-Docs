#!/bin/bash
# wake-pc.sh - wake the AI server (TPC2) from a Mac on the same LAN.
#
# Instant wake. No Homebrew, no dependencies -- macOS ships python3, which is
# all a magic packet needs. Copy this to the Mac, chmod +x, run it.
#
#   ./wake-pc.sh            # send the packet and wait for the box to answer
#   ./wake-pc.sh --send     # just send, do not wait
#   ./wake-pc.sh --listen   # no packet; only test whether the box is up
#
# WHY IT HAS TO BE THE LAN. A magic packet is a broadcast, and this Netgear
# cannot forward a broadcast from the WAN or hold a static ARP entry, so there
# is no wake-from-the-internet. On the LAN it is instant. From anywhere else,
# the box wakes itself on its own heartbeat timer instead (default every 20
# minutes) -- see docs/ai/RUNBOOKS.md on the server.

set -uo pipefail

PC_MAC="04:7C:16:3E:B4:6E"     # Marvell AQtion 10 GbE -- the wake-armed NIC
PC_IP="192.168.1.24"
BROADCAST="192.168.1.255"      # SUBNET broadcast; 255.255.255.255 is often dropped
PORTS=(9 7)                    # discard and echo; NICs sniff both
SSH_USER="poopl"

send_packet() {
  python3 - "$PC_MAC" "$BROADCAST" "${PORTS[@]}" <<'PY'
import socket, sys
mac, bcast = sys.argv[1], sys.argv[2]
ports = [int(p) for p in sys.argv[3:]]
raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
if len(raw) != 6:
    sys.exit("bad MAC: %s" % mac)
packet = b"\xff" * 6 + raw * 16           # the magic packet, 102 bytes
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in ports:
    for target in (bcast, "255.255.255.255"):
        try:
            s.sendto(packet, (target, port))
            print("  sent 102B to %s:%d" % (target, port))
        except OSError as e:
            print("  could not send to %s:%d (%s)" % (target, port, e))
PY
}

wait_for_host() {
  local tries=${1:-60}
  echo "waiting for $PC_IP to answer (up to ${tries}s)..."
  for i in $(seq 1 "$tries"); do
    if ping -c 1 -W 1000 "$PC_IP" >/dev/null 2>&1; then
      echo "UP after ${i}s"
      # ping answers a second or two before sshd is listening again
      for j in $(seq 1 30); do
        if nc -z -G 2 "$PC_IP" 22 >/dev/null 2>&1; then
          echo "ssh ready after $((i + j))s -> ssh ${SSH_USER}@${PC_IP}"
          return 0
        fi
        sleep 1
      done
      echo "host is up but ssh did not open within 30s"
      return 0
    fi
    sleep 1
  done
  echo "NO RESPONSE after ${tries}s"
  echo
  echo "Check, in this order:"
  echo "  1. Is this Mac on the same subnet? -> ifconfig | grep 'inet 192.168.1'"
  echo "  2. Was the PC actually asleep, or off at the wall? WoL needs standby power."
  echo "  3. On the PC (once awake): python C:\\AI-Server\\scripts\\wol-listen.py"
  echo "     then run this script again -- it says whether the packet arrives at all."
  return 1
}

case "${1:-}" in
  --listen)
    wait_for_host 10
    ;;
  --send)
    echo "waking $PC_MAC via $BROADCAST"
    send_packet
    ;;
  *)
    echo "waking $PC_MAC via $BROADCAST"
    send_packet
    echo
    wait_for_host 90
    ;;
esac
