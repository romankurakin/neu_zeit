set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git
# Release compilation needs more memory than serving the application.
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
curl -fsSL https://get.docker.com | sh
install -d -m 700 /opt/neu-zeit/application
cd /opt/neu-zeit/application
git init
git remote add origin "$REPOSITORY_URL"
git fetch --no-tags --depth 1 origin "$REVISION"
git checkout --detach FETCH_HEAD
umask 077
printf 'DATABASE_URL=ecto://postgres:%s@%s/neu_zeit\nSECRET_KEY_BASE=%s\nPHX_HOST=%s\n' \
  "$DATABASE_PASSWORD" "$DATABASE_HOST" "$SECRET_KEY_BASE" "$HOST" > .env
# This Compose file has no database service or database volume.
printf '%s' "$APPLICATION_COMPOSE" | base64 -d > compose.deploy.yaml
docker compose -f compose.deploy.yaml build application
for ((attempt = 0; attempt < 120; attempt++)); do
  if docker run --rm postgres:17-alpine pg_isready -h "$DATABASE_HOST" -U postgres -d neu_zeit; then
    break
  fi
  sleep 5
done
# Migrations must remain compatible with the old application during the handover.
docker compose -f compose.deploy.yaml run --rm migrate
docker compose -f compose.deploy.yaml up -d --wait --wait-timeout 180 application
cat > /opt/neu-zeit/Caddyfile <<CADDY
(deployment) {
  handle /__deployment {
    rewrite * /terms
    reverse_proxy 127.0.0.1:4000 {
      header_up X-Forwarded-Proto https
      header_down X-Deployment $REVISION
    }
  }
}
:80 {
  import deployment
}
$HOST {
  import deployment
  handle {
    reverse_proxy 127.0.0.1:4000
  }
}
CADDY

docker run -d --name caddy --restart unless-stopped --network host \
  -v /opt/neu-zeit/Caddyfile:/etc/caddy/Caddyfile:ro -v caddy_data:/data caddy:2
