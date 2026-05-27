#!/usr/bin/env bash
# Shared helpers: stable prod nginx bind mount and overlay network attach.
set -euo pipefail

NGINX_CONF_TARGET="${NGINX_CONF_TARGET:-/etc/nginx/nginx.conf}"
# Host path prod_nginx must mount (survives GHA checkout teardown).
HOST_NGINX_CONF="${HOST_NGINX_CONF:-/etc/nginx/swecc-api.conf}"

# Swarm inspect may return Docker Desktop's /host_mnt/... prefix; map to a host path we can write.
host_path_from_mount_source() {
  local p="$1"
  p="${p#/host_mnt}"
  if [[ -e "$p" ]]; then
    printf '%s' "$p"
    return 0
  fi
  if [[ "$p" == /private/* && -e "${p#/private}" ]]; then
    printf '%s' "${p#/private}"
    return 0
  fi
  printf '%s' "$p"
}

nginx_bind_mount_source() {
  local service_name="${1:?service name required}"
  local mounts_json
  mounts_json="$(docker service inspect "$service_name" \
    --format '{{json .Spec.TaskTemplate.ContainerSpec.Mounts}}' 2>/dev/null || echo 'null')"

  if [[ "$mounts_json" == "null" || "$mounts_json" == "[]" || -z "$mounts_json" ]]; then
    echo "ERROR: no mounts on service $service_name" >&2
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    local source
    source="$(printf '%s' "$mounts_json" | jq -r --arg t "$NGINX_CONF_TARGET" \
      '.[] | select(.Type == "bind" and .Target == $t) | .Source' | head -n1)"
    if [[ -n "$source" && "$source" != "null" ]]; then
      printf '%s' "$source"
      return 0
    fi
  fi

  echo "ERROR: no bind mount found for target $NGINX_CONF_TARGET on $service_name" >&2
  echo "Mounts: $mounts_json" >&2
  return 1
}

_abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  else
    (cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd)" "$(basename "$p")")
  fi
}

_validate_synced_nginx() {
  local host_path="$1"
  if ! grep -qE 'location .* /bench/' "$host_path"; then
    echo "ERROR: synced file missing /bench/ routes" >&2
    return 1
  fi
  if ! grep -qE 'location = /bench[[:space:]]*\{' "$host_path"; then
    echo "ERROR: synced file missing exact /bench route (Mesocosm CORS)" >&2
    return 1
  fi
  echo "OK: synced nginx.conf includes /bench routes"
}

# Write repo nginx.conf to HOST_NGINX_CONF and point prod_nginx at that path.
publish_nginx_conf_for_swarm() {
  local service_name="${1:?service name required}"
  local source_conf="${2:-nginx.conf}"

  if [[ ! -f "$source_conf" ]]; then
    echo "ERROR: $source_conf not found" >&2
    return 1
  fi

  echo "Publishing $source_conf -> $HOST_NGINX_CONF"
  sudo mkdir -p "$(dirname "$HOST_NGINX_CONF")"
  sudo cp "$source_conf" "$HOST_NGINX_CONF"
  sudo chmod 644 "$HOST_NGINX_CONF"
  _validate_synced_nginx "$HOST_NGINX_CONF"

  local mount_source host_path
  mount_source="$(nginx_bind_mount_source "$service_name")"
  host_path="$(host_path_from_mount_source "$mount_source")"

  echo "Service: $service_name"
  echo "Current mount source: $mount_source"

  if [[ "$host_path" == "$(_abs_path "$HOST_NGINX_CONF")" ]]; then
    echo "OK: service already mounts $HOST_NGINX_CONF"
    return 0
  fi

  echo "Updating $service_name bind mount -> $HOST_NGINX_CONF"
  docker service update \
    --mount-rm "$NGINX_CONF_TARGET" \
    --mount-add "type=bind,source=${HOST_NGINX_CONF},target=${NGINX_CONF_TARGET},readonly" \
    "$service_name"
}

# Back-compat name used by older scripts.
sync_nginx_conf_to_service_mount() {
  publish_nginx_conf_for_swarm "$@"
}

service_on_network() {
  local service_name="${1:?service name required}"
  local network_name="${2:?network name required}"
  local target net_name

  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    net_name="$(docker network inspect "$target" --format '{{.Name}}' 2>/dev/null || true)"
    if [[ "$net_name" == "$network_name" ]]; then
      return 0
    fi
  done < <(
    docker service inspect "$service_name" \
      --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}}{{println}}{{end}}'
  )
  return 1
}

ensure_service_on_network() {
  local service_name="${1:?service name required}"
  local network_name="${2:-prod_swecc-network}"

  if service_on_network "$service_name" "$network_name"; then
    echo "OK: $service_name already on $network_name"
    return 0
  fi

  echo "Adding $network_name to $service_name..."
  local out
  if out="$(docker service update --network-add "name=${network_name}" "$service_name" 2>&1)"; then
    return 0
  fi
  if echo "$out" | grep -qiE 'already attached to network|service is already attached'; then
    echo "OK: $network_name already attached ($service_name)"
    return 0
  fi
  echo "$out" >&2
  return 1
}
