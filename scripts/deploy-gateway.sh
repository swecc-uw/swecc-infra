#!/usr/bin/env bash
# Deploy or repair the prod API gateway (Swarm stack prod → service prod_nginx, :80/:443).
set -euo pipefail

STACK_NAME="${STACK_NAME:-prod}"
SERVICE_NAME="${SERVICE_NAME:-prod_nginx}"
APP_NETWORK="${APP_NETWORK:-prod_swecc-network}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[deploy-gateway] $*"; }
die() { echo "[deploy-gateway] ERROR: $*" >&2; exit 1; }

dump_service_debug() {
  docker service ps "$SERVICE_NAME" --no-trunc 2>/dev/null || true
  local cid
  cid="$(docker ps -aq -f name=prod_nginx | head -1 || true)"
  if [[ -n "$cid" ]]; then
    docker logs "$cid" --tail 40 2>&1 || true
  fi
}

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

validate_nginx_conf() {
  log "nginx -t on ${APP_NETWORK} (resolves server/sockets/bench-api)"
  if ! docker run --rm \
    --network "$APP_NETWORK" \
    -v "${REPO_ROOT}/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v /etc/letsencrypt:/etc/letsencrypt:ro \
    nginx:stable-alpine nginx -t; then
    die "nginx.conf failed validation — fix before deploying"
  fi
}

wait_for_service() {
  local max_attempts="${1:-60}"
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
  dump_service_debug
  die "$SERVICE_NAME did not reach Running"
}

reload_running_nginx() {
  local cid
  cid="$(docker ps -q -f name=prod_nginx | head -1 || true)"
  [[ -n "$cid" ]] || return 1
  docker exec "$cid" nginx -t
  docker exec "$cid" nginx -s reload
  log "reloaded nginx in container $cid"
  return 0
}

roll_service_forward() {
  log "rolling $SERVICE_NAME forward (start-first, no rollback)"
  docker service update \
    --force \
    --update-parallelism 1 \
    --update-order start-first \
    --update-failure-action pause \
    "$SERVICE_NAME"
}

verify_host_listeners() {
  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi
  ss -tln 2>/dev/null | grep -E ':80 |:443 ' || log "WARN: :80/:443 not yet in ss output"
}

verify_local_https() {
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve api.swecc.org:443:127.0.0.1 \
    --max-time 15 \
    https://api.swecc.org/health/ || true)"
  log "curl https://api.swecc.org/health/ via 127.0.0.1 -> HTTP $code"
  case "$code" in
    200|503) return 0 ;;
    *) die "expected 200 or 503 from /health/, got: ${code:-none}" ;;
  esac
}

main() {
  require_cmd docker
  require_cmd jq

  cd "$REPO_ROOT"
  [[ -f stack.yml && -f nginx.conf ]] || die "stack.yml and nginx.conf required in $REPO_ROOT"

  if ! docker network inspect "$APP_NETWORK" >/dev/null 2>&1; then
    die "overlay network $APP_NETWORK missing"
  fi

  validate_nginx_conf

  export PWD="$REPO_ROOT"
  log "stack deploy -c stack.yml $STACK_NAME (PWD=$PWD)"
  docker stack deploy -c stack.yml "$STACK_NAME"

  docker service inspect "$SERVICE_NAME" >/dev/null 2>&1 \
    || die "service $SERVICE_NAME not found after stack deploy"

  ensure_published_port 80
  ensure_published_port 443

  # shellcheck source=scripts/nginx-mount-path.sh
  . "${REPO_ROOT}/scripts/nginx-mount-path.sh"
  sync_nginx_conf_to_service_mount "$SERVICE_NAME" nginx.conf

  if reload_running_nginx; then
    log "config applied via reload (no swarm task replace)"
  else
    roll_service_forward
    wait_for_service 90
  fi

  verify_host_listeners
  verify_local_https
  log "gateway deploy finished OK"
}

main "$@"
