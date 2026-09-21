set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl
curl -fsSL https://get.docker.com | sh
PRIVATE_IP=$(curl -fsS http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)
install -d -m 700 /opt/neu-zeit/database
printf 'POSTGRES_PASSWORD=%s\n' "$DATABASE_PASSWORD" > /opt/neu-zeit/database/environment
chmod 600 /opt/neu-zeit/database/environment
# PostgreSQL listens only on the private interface; the cloud firewall also restricts callers.
docker run -d --name database --restart unless-stopped \
  --env-file /opt/neu-zeit/database/environment \
  -e POSTGRES_USER=postgres -e POSTGRES_DB=neu_zeit \
  -p "$PRIVATE_IP:5432:5432" -v neu_zeit_database:/var/lib/postgresql/data postgres:17-alpine
install -d -m 700 /opt/neu-zeit/backups
cat > /etc/cron.daily/neu-zeit-backup <<'BACKUP'
#!/bin/bash
set -euo pipefail
umask 077
cd /opt/neu-zeit/backups
output="$(date -u +%Y%m%d).dump"
docker exec database pg_dump -U postgres -d neu_zeit -Fc > "$output.partial"
test -s "$output.partial"
mv "$output.partial" "$output"
find . -name '*.dump' -mtime +7 -delete
BACKUP
chmod 700 /etc/cron.daily/neu-zeit-backup
