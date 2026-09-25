#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
# Network first: WSL's generated resolv.conf points at IPv6 DNS proxies that never
# answer here, and apt/curl hang on IPv6. wsl.conf stops the regeneration.
install -m 644 /mnt/c/wsl/pp-setup/wsl.conf /etc/wsl.conf
rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
rm -f /etc/apt/apt.conf.d/20apt-esm-hook.conf
grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
timeout 300 apt-get update -qq
apt-get install -y -qq iptables openssh-server python3-venv python3-pip build-essential git curl wget tmux htop unzip ca-certificates >/dev/null
update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
id antoine >/dev/null 2>&1 || useradd -m -s /bin/bash antoine
# Ubuntu cloud images add the first user to sudo; make sure he is not.
gpasswd -d antoine sudo >/dev/null 2>&1 || true
passwd -l antoine >/dev/null
install -d -m 700 -o antoine -g antoine /home/antoine/.ssh
touch /home/antoine/.ssh/authorized_keys; chown antoine:antoine /home/antoine/.ssh/authorized_keys; chmod 600 /home/antoine/.ssh/authorized_keys
install -m 755 /mnt/c/wsl/pp-setup/pp-boot.sh /usr/local/sbin/pp-boot.sh
install -m 644 /mnt/c/wsl/pp-setup/sshd_config_pp /etc/ssh/sshd_config_pp
ssh-keygen -A >/dev/null
systemctl disable ssh >/dev/null 2>&1 || true
install -m 644 /mnt/c/wsl/pp-setup/README-antoine.md /home/antoine/README.md
chown antoine:antoine /home/antoine/README.md
echo "setup ok; antoine groups: $(id -nG antoine)"
