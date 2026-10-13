#!/usr/bin/env bash
set -euo pipefail
umask 077
chmod 700 /opt/neu-zeit

# Micro has 1 GB of RAM. Swap uses the existing boot disk, with no extra cloud volume.
if [[ -z "$(swapon --noheadings --show=NAME)" ]]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  printf '%s\n' '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

# SSH accepts only Bastion sessions; the cloud network permits port 22 from its private endpoint.
install -d -m 755 /etc/ssh/sshd_config.d
printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' 'AllowUsers opc' \
  > /etc/ssh/sshd_config.d/00-neu-zeit.conf
sshd -t
systemctl enable --now sshd
systemctl reload sshd

dnf install -y dnf-plugins-core python3.11 python3.11-pip curl

# Oracle Linux 9 uses the EL9 packages. Keep RPM signature verification enabled.
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf remove -y podman podman-docker runc
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
install -d -m 755 /etc/docker
printf '%s\n' '{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3"}}' > /etc/docker/daemon.json
systemctl enable --now docker

python3.11 -m venv /opt/neu-zeit/sdk
/opt/neu-zeit/sdk/bin/pip install --disable-pip-version-check 'oci==2.187.2'

cat > /usr/local/sbin/neu-zeit << 'WRAPPER'
#!/bin/bash
set -euo pipefail
for _attempt in {1..60}; do
  if test -f /opt/neu-zeit/boot-ready; then break; fi
  sleep 5
done
test -f /opt/neu-zeit/boot-ready
exec /opt/neu-zeit/sdk/bin/python /opt/neu-zeit/host.py "$@"
WRAPPER
chmod 755 /usr/local/sbin/neu-zeit
printf '%s\n' 'ocarun ALL=(root) NOPASSWD: /usr/local/sbin/neu-zeit *' > /etc/sudoers.d/100-neu-zeit
chmod 440 /etc/sudoers.d/100-neu-zeit
visudo -cf /etc/sudoers.d/100-neu-zeit

if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --remove-service=ssh
  bastion_ip=$(/opt/neu-zeit/sdk/bin/python -c 'import json; print(json.load(open("/opt/neu-zeit/config.json"))["bastion_ip"])')
  firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$bastion_ip/32\" port port=\"22\" protocol=\"tcp\" accept"
  if /opt/neu-zeit/sdk/bin/python -c 'import json; exit(json.load(open("/opt/neu-zeit/config.json"))["role"] != "application")'; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
  else
    firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.42.0.10/32" port port="5432" protocol="tcp" accept'
  fi
  firewall-cmd --reload
fi

cat > /etc/systemd/system/neu-zeit-backup.service << 'SERVICE'
[Unit]
Description=NeuZeit PostgreSQL backup
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/neu-zeit backup
SERVICE

cat > /etc/systemd/system/neu-zeit-backup.timer << 'TIMER'
[Unit]
Description=Daily NeuZeit PostgreSQL backup
[Timer]
OnCalendar=*-*-* 03:00:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
touch /opt/neu-zeit/boot-ready
