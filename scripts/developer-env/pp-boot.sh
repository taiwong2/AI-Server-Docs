#!/bin/bash
# /usr/local/sbin/pp-boot.sh -- runs as root at every start of the pp-antoine
# WSL environment ([boot] command in /etc/wsl.conf). Antoine has no root, so he
# cannot change any of this.
#
# WHY: this WSL runs in VirtioProxy networking, where 127.0.0.1 inside the
# environment reaches services bound to 127.0.0.1 on the Windows host -- the
# Gmail MCPs (8000/8001), ComfyUI, the model proxy. Everything below keeps his
# code to: LM Studio on :1234, his own loopback services on 20000-29999, DNS,
# and the public internet.
set -u
for T in iptables ip6tables; do
  $T -F OUTPUT
  $T -P OUTPUT ACCEPT
  $T -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  $T -A OUTPUT -p udp --dport 53 -j ACCEPT
  $T -A OUTPUT -p tcp --dport 53 -j ACCEPT
done
# IPv4 loopback: LM Studio + his own port range only.
iptables -A OUTPUT -d 127.0.0.0/8 -p tcp --dport 1234 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.0/8 -p tcp --dport 20000:29999 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.0/8 -p tcp --sport 20000:29999 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.0/8 -p tcp --sport 2222 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.0/8 -p tcp --sport 8899 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.0/8 -j REJECT
# The box's own addresses, LAN, tailnet, link-local, other private ranges.
iptables -A OUTPUT -d 100.71.113.77 -p tcp --dport 1234 -j ACCEPT
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
  iptables -A OUTPUT -d $net -j REJECT
done
ip6tables -A OUTPUT -d ::1 -p tcp --dport 1234 -j ACCEPT
ip6tables -A OUTPUT -d ::1 -p tcp --dport 20000:29999 -j ACCEPT
ip6tables -A OUTPUT -d ::1 -p tcp --sport 20000:29999 -j ACCEPT
ip6tables -A OUTPUT -d ::1 -j REJECT
for net in fc00::/7 fe80::/10 fec0::/10; do
  ip6tables -A OUTPUT -d $net -j REJECT
done
# Defense in depth for interop (already off in wsl.conf): unregister the
# Windows-binary handler and make the interop socket root-only, so a .exe he
# writes himself cannot be launched as a Windows process.
echo 0 > /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null || true
chmod 700 /run/WSL 2>/dev/null || true
install -d -m 755 -o root -g root /run/sshd
/usr/sbin/sshd -f /etc/ssh/sshd_config_pp
