#!/usr/bin/env bash
set -euo pipefail

: "${DEMO_RESERVED_IP:?Set the DEMO_RESERVED_IP repository variable to the permanent IPv4 address}"
: "${DROPLET:=neu-zeit-demo}"
: "${RECREATE:=false}"
: "${REVISION:=main}"
: "${SIZE:=s-2vcpu-2gb}"

report() {
  printf '%s\n' "$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

fail() { echo "$1" >&2; exit 1; }

wait_action() {
  local status
  status=$(doctl compute action wait "$1" --format Status --no-header)
  [[ "$status" == completed ]] || fail "DigitalOcean action $1 ended with status $status."
}

[[ "$DEMO_RESERVED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'Expected an IPv4 address.'
[[ "$RECREATE" == true || "$RECREATE" == false ]] || fail 'RECREATE must be true or false.'
MODE=${1:?Expected deploy or undeploy}
[[ "$MODE" == deploy || "$MODE" == undeploy ]] || fail 'Expected deploy or undeploy.'
HOST="${DEMO_RESERVED_IP//./-}.sslip.io"
TAG="demo-ip-${DEMO_RESERVED_IP//./-}"

# Never choose an arbitrary unassigned address: it may belong to another app.
RESERVED_LIST=$(doctl compute reserved-ip list --output json)
RESERVED=$(jq --arg ip "$DEMO_RESERVED_IP" '[.[] | select(.ip == $ip)]' <<< "$RESERVED_LIST")
REGION=$(jq -r '.[0].region.slug // empty' <<< "$RESERVED")
OWNER=$(jq -r '.[0].droplet.id // empty' <<< "$RESERVED")
DROPLETS=$(doctl compute droplet list --output json)
MATCHES=$(jq --arg name "$DROPLET" '[.[] | select(.name == $name)]' <<< "$DROPLETS")
COUNT=$(jq length <<< "$MATCHES")
[[ "$COUNT" -le 1 ]] || fail "Multiple droplets named $DROPLET; resolve the duplicate before deploying."
ID=$(jq -r '.[0].id // empty' <<< "$MATCHES")
[[ -z "$OWNER" || "$OWNER" == "$ID" ]] || fail 'The reserved IP belongs to a different droplet; refusing to move it.'

if [[ "$MODE" == deploy ]]; then
  [[ -n "$REGION" ]] || fail 'Reserved IP no longer exists. Reserve a new IPv4 in DigitalOcean and update DEMO_RESERVED_IP before deploying.'
  [[ "$REVISION" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail 'Expected a branch, tag or commit.'
  : "${REPOSITORY_URL:?Set the Git repository URL}"
  [[ "$REPOSITORY_URL" =~ ^https://[A-Za-z0-9./_-]+\.git$ ]] || fail 'Expected an HTTPS Git repository URL.'
  if [[ -n "$ID" ]]; then
    [[ "$(jq -r '.[0].region.slug' <<< "$MATCHES")" == "$REGION" ]] || fail 'The droplet and reserved IP must be in the same region.'
    if [[ "$RECREATE" == false ]]; then
      jq -e --arg tag "$TAG" '.[0].tags | index($tag) != null' <<< "$MATCHES" >/dev/null \
        || fail 'This demo predates the permanent URL. Select Recreate demo to install it (deletes the demo database).'
    fi
  fi
  # Prepare boot configuration before any destructive operation.
  BOOT=$(mktemp)
  trap 'rm -f "$BOOT"' EXIT
  sed -e "s|__REPOSITORY__|$REPOSITORY_URL|g" \
      -e "s|__REVISION__|$REVISION|g" \
      -e "s|__HOST__|$HOST|g" \
      "$(dirname "$0")/cloud-init.yaml" > "$BOOT"
fi

if [[ -n "$ID" && ( "$MODE" == undeploy || "$RECREATE" == true ) ]]; then
  if [[ -n "$OWNER" ]]; then
    ACTION=$(doctl compute reserved-ip-action unassign "$DEMO_RESERVED_IP" --format ID --no-header)
    wait_action "$ACTION"
    OWNER=
  fi
  # Recreate keeps the IP; full undeploy releases it after the droplet is gone.
  doctl compute droplet delete "$ID" --force
  for ((attempt = 0; attempt < 60; attempt++)); do
    REMAINING=$(doctl compute droplet list --output json)
    if ! jq -e --argjson id "$ID" 'any(.[]; .id == $id)' <<< "$REMAINING" >/dev/null; then
      ID=
      break
    fi
    sleep 5
  done
  [[ -z "$ID" ]] || fail 'Droplet deletion is still pending; retry after it completes.'
fi

if [[ "$MODE" == undeploy ]]; then
  if [[ -n "$REGION" ]]; then
    doctl compute reserved-ip delete "$DEMO_RESERVED_IP" --force
    REMAINING_IPS=$(doctl compute reserved-ip list --output json)
    RELEASED=$(jq --arg ip "$DEMO_RESERVED_IP" 'all(.[]; .ip != $ip)' <<< "$REMAINING_IPS")
    [[ "$RELEASED" == true ]] || fail 'Reserved IP deletion is still pending; retry undeploy.'
  fi
  report 'Demo server, database and reserved IP removed. No billable resources created by these workflows remain.'
  report 'For a new demo, reserve a new IPv4 and update DEMO_RESERVED_IP. The previous URL is no longer reserved.'
  exit 0
fi

CREATED=false
if [[ -z "$ID" ]]; then
  ID=$(doctl compute droplet create "$DROPLET" \
    --image ubuntu-24-04-x64 --size "$SIZE" --region "$REGION" \
    --user-data-file "$BOOT" --tag-name "$TAG" \
    --enable-monitoring --wait --format ID --no-header)
  CREATED=true
fi
if [[ "$OWNER" != "$ID" ]]; then
  ACTION=$(doctl compute reserved-ip-action assign "$DEMO_RESERVED_IP" "$ID" --format ID --no-header)
  wait_action "$ACTION"
fi
report "### Demonstration host"
report "https://$HOST"
if [[ "$CREATED" == true ]]; then
  report 'The first boot builds the release. HTTPS becomes available a few minutes later.'
else
  report 'Existing demo retained. Select Recreate demo to deploy another revision with a fresh database.'
fi
