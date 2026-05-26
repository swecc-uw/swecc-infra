#!/usr/bin/env bash
# Shared helpers: resolve prod nginx bind-mount source and sync nginx.conf there.
set -euo pipefail

NGINX_CONF_TARGET="${NGINX_CONF_TARGET:-/etc/nginx/nginx.conf}"

# Swarm inspect may return Docker Desktop's /host_mnt/... prefix; map to a host path we can write.
host_path_from_mount_source() {
  local p="$1"
  p="${p#/host_mnt}"
  if [[ -e "$p" ]]; then
    printf '%s' "$p"
    return 0
  fi
  # macOS: /var/... is often /private/var/...
  if [[ "$p" == /private/* && -e "${p#/private}" ]]; then
    printf '%s' "${p#/private}"
    return 0
  fi
  printf '%s' "$p"
}

# Print the host path bind-mounted to NGINX_CONF_TARGET for a Swarm service.
nginx_bind_mount_source() {
  local service_name="${1:?service name required}"
  local mounts_json
  mounts_json="$(docker service inspect "$service_name" \
    --format '{{json .Spec.TaskTemplate.ContainerSpec.Mounts}}' 2>/dev/null || echo 'null')"

  if [[ "$mounts_json" == "null" || "$mounts_json" == "[]" || -z "$mounts_json" ]]; then
    echo "ERROR: no mounts on service $service_name" >&2
    return 1
  fi

  # Prefer jq when available; fall back to a minimal grep/sed parser.
  if command -v jq >/dev/null 2>&1; then
    local source
    source="$(printf '%s' "$mounts_json" | jq -r --arg t "$NGINX_CONF_TARGET" \
      '.[] | select(.Type == "bind" and .Target == $t) | .Source' | head -n1)"
    if [[ -n "$source" && "$source" != "null" ]]; then
      printf '%s' "$source"
      return 0
    fi
  else
    local source
    source="$(printf '%s' "$mounts_json" | tr ',' '\n' \
      | grep -F "\"Target\":\"$NGINX_CONF_TARGET\"" \
      | sed -n 's/.*"Source":"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ -n "$source" ]]; then
      printf '%s' "$source"
      return 0
    fi
  fi

  echo "ERROR: no bind mount found for target $NGINX_CONF_TARGET on $service_name" >&2
  echo "Mounts: $mounts_json" >&2
  return 1
}

# Resolve to an absolute path (Linux runners; used to detect same-file bind mounts).
_abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  else
    (cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd)" "$(basename "$p")")
  fi
}

# Copy repo nginx.conf to the path the running service actually reads.
sync_nginx_conf_to_service_mount() {
  local service_name="${1:?service name required}"
  local source_conf="${2:-nginx.conf}"

  if [[ ! -f "$source_conf" ]]; then
    echo "ERROR: $source_conf not found" >&2
    return 1
  fi

  local mount_source host_path src_abs dest_abs
  mount_source="$(nginx_bind_mount_source "$service_name")"
  host_path="$(host_path_from_mount_source "$mount_source")"
  src_abs="$(_abs_path "$source_conf")"
  dest_abs="$(_abs_path "$host_path")"

  echo "Service: $service_name"
  echo "Mount source (inspect): $mount_source"
  echo "Host path (write): $host_path"

  if [[ "$src_abs" == "$dest_abs" ]]; then
    echo "OK: bind mount already uses checkout nginx.conf (no copy needed)"
  else
    echo "Copying $source_conf -> $host_path"
    mkdir -p "$(dirname "$host_path")"
    cp "$source_conf" "$host_path"
  fi

  if ! grep -qE 'location .* /bench/' "$host_path"; then
    echo "ERROR: synced file missing /bench/ routes" >&2
    return 1
  fi

  echo "OK: synced nginx.conf includes /bench/ routes"
}
