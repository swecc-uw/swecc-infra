#!/usr/bin/env bash
# Deploy or repair the prod API gateway (Swarm stack prod → service prod_nginx, :80/:443).
set -euo pipefail

STACK_NAME="${STACK_NAME:-prod}"
# stack.yml service key is "nginx"; Swarm name is prod_nginx when STACK_NAME=prod.
SERVICE_NAME="${SERVICE_NAME:-prod_nginx}"
APP_NETWORK="${APP_NETWORK:-prod_swecc-network}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[deploy-gateway] $*"; }
die() { echo "[deploy-gateway] ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

service_has_published_port() {
  local port="$1"
  docker service inspect "$SERVICE_NAME" \
    --format '{{json .Endpoint.Ports}}' 2>/dev/null \
    | jq -e --argjson p "$port" '.[] | select(.PublishedPort == $p)' >/dev/null
}

ensure_published_port() {
  local port="$1"
  if service_has_published_port "$port"; then
    log "Published port $port already configured on $SERVICE_NAME"
    return 0
  fi
  log "Adding ingress publish $port -> $port on $SERVICE_NAME"
  docker service update \
    --publish-add "published=${port},target=${port},protocol=tcp,mode=ingress" \
    "$SERVICE_NAME"
}

wait_for_service() {
  local max_attempts="${1:-30}"
  local attempt=0
  while [[ $attempt -lt $max_attempts ]]; do
    if docker service ps "$SERVICE_NAME" --filter "desired-state=running" --format "{{.CurrentState}}" \
      | grep -q "Running"; then
      log "$SERVICE_NAME has a running task"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  die "$SERVICE_NAME did not reach Running; see: docker service ps $SERVICE_NAME --no-trunc"
}

verify_host_listeners() {
  local missing=0
  if command -v ss >/dev/null 2>&1; then
    if ! ss -tln 2>/dev/null | grep -qE ':80 '; then
      log "WARN: nothing listening on :80 (ingress may still be starting)"
      missing=$((missing + 1))
    fi
    if ! ss -tln 2>/dev/null | grep -qE ':443 '; then
      log "WARN: nothing listening on :443 (ingress may still be starting)"
      missing=$((missing + 1))
    fi
  fi
  if [[ $missing -gt 0 ]]; then
    log "Published ports: $(docker service inspect "$SERVICE_NAME" --format '{{json .Endpoint.Ports}}')"
  fi
}

verify_local_https() {
  if ! command -v curl >/dev/null 2>&1; then
    log "skip curl check (curl not installed)"
    return 0
  fi
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve api.swecc.org:443:127.0.0.1 \
    --max-time 10 \
    https://api.swecc.org/health/ || true)"
  log "curl https://api.swecc.org/health/ via 127.0.0.1 -> HTTP $code"
  case "$code" in
    200|503) return 0 ;;
    *) die "expected 200 or 503 from /health/ through gateway, got: ${code:-none}" ;;
  esac
}

main() {
  require_cmd docker
  require_cmd jq

  cd "$REPO_ROOT"
  [[ -f stack.yml ]] || die "stack.yml not found in $REPO_ROOT"
  [[ -f nginx.conf ]] || die "nginx.conf not found in $REPO_ROOT"

  if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -qE 'manager|active'; then
    die "this host must be a Swarm manager (got: $(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo unknown))"
  fi

  if ! docker network inspect "$APP_NETWORK" >/dev/null 2>&1; then
    die "overlay network $APP_NETWORK missing — create it before deploying the gateway"
  fi

  export PWD="$REPO_ROOT"
  log "stack deploy -c stack.yml $STACK_NAME (PWD=$PWD)"
  docker stack deploy -c stack.yml "$STACK_NAME"

  if ! docker service inspect "$SERVICE_NAME" >/dev/null 2>&1; then
    die "service $SERVICE_NAME not found after stack deploy (expected stack service 'nginx' -> prod_nginx)"
  fi

  ensure_published_port 80
  ensure_published_port 443

  # shellcheck source=scripts/nginx-mount-path.sh
  . "${REPO_ROOT}/scripts/nginx-mount-path.sh"
  sync_nginx_conf_to_service_mount "$SERVICE_NAME" nginx.conf

  log "rolling $SERVICE_NAME (config sync + image refresh)"
  docker service update \
    --force \
    --update-parallelism 1 \
    --update-order start-first \
    --update-failure-action rollback \
    "$SERVICE_NAME"

  wait_for_service 60
  verify_host_listeners
  verify_local_https
  log "gateway deploy finished OK"
}

main "$@"
