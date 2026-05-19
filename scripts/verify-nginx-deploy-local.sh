#!/usr/bin/env bash
# Local verification for nginx bind-mount deploy behavior.
#
#   ./scripts/verify-nginx-deploy-local.sh --unit     # no Docker daemon
#   ./scripts/verify-nginx-deploy-local.sh --swarm    # full Swarm repro (needs Docker)
#   ./scripts/verify-nginx-deploy-local.sh            # unit + swarm if Docker is up
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/nginx-mount-path.sh
. "$ROOT/scripts/nginx-mount-path.sh"

STACK_NAME="verify_nginx_mount"
SERVICE_NAME="${STACK_NAME}_nginx"
FAILED=0
LE_DIR=""

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

# Docker Desktop on macOS reports bind sources under /host_mnt/...
canonical_path() {
  local p="$1"
  p="${p#/host_mnt}"
  if [[ -e "$p" ]]; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p"
  else
    printf '%s' "$p"
  fi
}

paths_equal() {
  [[ "$(canonical_path "$1")" == "$(canonical_path "$2")" ]]
}

prepare_stub_tls() {
  LE_DIR="$(mktemp -d)"
  mkdir -p "$LE_DIR/live/api.swecc.org"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$LE_DIR/live/api.swecc.org/privkey.pem" \
    -out "$LE_DIR/live/api.swecc.org/fullchain.pem" \
    -days 1 -subj "/CN=api.swecc.org" 2>/dev/null
}

run_unit_tests() {
  echo "=== Unit tests (mock docker service inspect) ==="

  local mock_json='[{"Type":"bind","Source":"/tmp/old-checkout/nginx.conf","Target":"/etc/nginx/nginx.conf","ReadOnly":true}]'
  local got
  got="$(printf '%s' "$mock_json" | jq -r --arg t "$NGINX_CONF_TARGET" \
    '.[] | select(.Type == "bind" and .Target == $t) | .Source' | head -n1)"
  if [[ "$got" == "/tmp/old-checkout/nginx.conf" ]]; then
    pass "jq extracts bind mount source"
  else
    fail "jq extract got '$got'"
  fi

  if grep -q 'location /bench/' "$ROOT/nginx.conf"; then
    pass "repo nginx.conf contains /bench/ routes"
  else
    fail "repo nginx.conf missing /bench/ routes"
  fi

  echo ""
  echo "=== nginx -t (config syntax) ==="
  if docker_ready; then
    prepare_stub_tls
    if docker run --rm \
      -v "$ROOT/nginx.conf:/etc/nginx/nginx.conf:ro" \
      -v "$LE_DIR:/etc/letsencrypt:ro" \
      nginx:stable-alpine nginx -t 2>&1; then
      pass "nginx -t"
    else
      fail "nginx -t"
    fi
    rm -rf "$LE_DIR"
    LE_DIR=""
  else
    echo "SKIP: docker daemon unavailable — start Docker Desktop, then re-run"
  fi
}

docker_ready() {
  perl -e 'alarm 8; exec @ARGV' docker info >/dev/null 2>&1
}

run_swarm_repro() {
  echo ""
  echo "=== Swarm repro: checkout path != mount path ==="

  if ! docker_ready; then
    echo "SKIP: Docker daemon not reachable (start Docker Desktop and re-run with --swarm)"
    return 0
  fi

  docker swarm init --advertise-addr 127.0.0.1 2>/dev/null || true
  docker stack rm -f "$STACK_NAME" 2>/dev/null || true
  docker service rm "$SERVICE_NAME" 2>/dev/null || true
  sleep 3

  prepare_stub_tls

  local dir_a dir_b
  dir_a="$(mktemp -d)"
  dir_b="$(mktemp -d)"
  cleanup_swarm_test() {
    docker stack rm -f "$STACK_NAME" 2>/dev/null || true
    rm -rf "$dir_a" "$dir_b" "$LE_DIR"
    LE_DIR=""
  }

  cp "$ROOT/nginx.conf" "$dir_a/nginx.conf"
  cp "$ROOT/nginx.conf" "$dir_b/nginx.conf"

  # Marker A: only in dir_a file at deploy time
  echo "# VERIFY_MARKER_A" >> "$dir_a/nginx.conf"
  echo "# VERIFY_MARKER_B" >> "$dir_b/nginx.conf"

  mkdir -p "$dir_a/html"
  cat >"$dir_a/stack.yml" <<EOF
version: '3.8'
services:
  nginx:
    image: nginx:stable-alpine
    volumes:
      - ${LE_DIR}:/etc/letsencrypt:ro
      - \${PWD}/html:/usr/share/nginx/html:ro
      - \${PWD}/nginx.conf:/etc/nginx/nginx.conf
    ports:
      - "18080:80"
      - "18443:443"
networks:
  default:
    driver: overlay
EOF

  (
    cd "$dir_a"
    docker stack deploy -c stack.yml "$STACK_NAME"
  )

  echo "Waiting for nginx task..."
  local i
  for i in $(seq 1 30); do
    if docker service ls --filter "name=${SERVICE_NAME}" --format '{{.Replicas}}' 2>/dev/null | grep -q '1/1'; then
      break
    fi
    sleep 2
  done

  local mount_source
  mount_source="$(nginx_bind_mount_source "$SERVICE_NAME")"
  pass "resolved mount source: $mount_source"

  if ! paths_equal "$mount_source" "$dir_a/nginx.conf"; then
    fail "expected mount $dir_a/nginx.conf got $mount_source"
  else
    pass "mount path matches deploy-time PWD (normalized)"
  fi

  wait_for_nginx_container() {
    local cid=""
    for _ in $(seq 1 30); do
      cid="$(docker ps -q --filter "name=${STACK_NAME}_nginx" --filter "status=running" | head -n1)"
      if [[ -n "$cid" ]]; then
        printf '%s' "$cid"
        return 0
      fi
      sleep 2
    done
    return 1
  }

  local container_id marker
  container_id="$(wait_for_nginx_container)" || true
  if [[ -z "$container_id" ]]; then
    fail "no running nginx container"
    return
  fi

  marker="$(docker exec "$container_id" grep -o 'VERIFY_MARKER_[AB]' /etc/nginx/nginx.conf | head -n1 || true)"
  if [[ "$marker" == "VERIFY_MARKER_A" ]]; then
    pass "without sync: container still reads dir_a config (marker A)"
  else
    fail "without sync: expected VERIFY_MARKER_A in container, got '$marker'"
  fi

  # Apply fix: copy from dir_b (simulated checkout) to frozen mount path
  sync_nginx_conf_to_service_mount "$SERVICE_NAME" "$dir_b/nginx.conf"

  # Bind mounts are live — no stack update required for the file to change in-container.
  container_id="$(wait_for_nginx_container)" || true
  marker="$(docker exec "$container_id" grep -o 'VERIFY_MARKER_[AB]' /etc/nginx/nginx.conf | head -n1 || true)"
  if [[ "$marker" == "VERIFY_MARKER_B" ]]; then
    pass "with sync: container reads updated config (marker B)"
  else
    fail "with sync: expected VERIFY_MARKER_B in container, got '$marker'"
  fi

  cleanup_swarm_test
}

MODE="${1:---all}"
case "$MODE" in
  --unit) run_unit_tests ;;
  --swarm) run_swarm_repro ;;
  --all|*)
    run_unit_tests
    run_swarm_repro
    ;;
esac

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "All checks passed."
  exit 0
fi
echo "Some checks failed."
exit 1
