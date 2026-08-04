#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

expected_commit="${1:?usage: traccar-sf-test-position-mirror.sh EXPECTED_COMMIT preflight|dry-run|activate|stop|status}"
action="${2:?missing action}"
case "$action" in
  preflight|dry-run|activate|stop|status) ;;
  *) echo "Action must be preflight, dry-run, activate, stop, or status" >&2; exit 2 ;;
esac
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]

repo_dir="/opt/traccar-dev"
runtime_file="/etc/traccar-dev/runtime.env"
event_file="/etc/traccar-dev/forward.env"
mirror_file="/etc/traccar-dev/position-mirror.env"
base_file="$repo_dir/docker/compose/sf-test-server.yaml"
event_override="$repo_dir/docker/compose/sf-test-server-forward.yaml"
mirror_override="$repo_dir/docker/compose/sf-test-server-position-mirror.yaml"
project="traccar-dev"
expected_position_url="https://sf-test-server.tail056d0a.ts.net/fleet-test/api/v1/internal/gps/traccar/positions"
expected_fleet_health="https://sf-test-server.tail056d0a.ts.net/fleet-test/api/v1/health"

env_value() {
  local file="$1"
  local name="$2"
  awk -F= -v name="$name" '$1 == name {print substr($0, index($0, "=") + 1)}' "$file"
}

normal_compose() {
  docker compose -p "$project" \
    --env-file "$runtime_file" --env-file "$event_file" \
    -f "$base_file" -f "$event_override" "$@"
}

mirror_compose() {
  docker compose -p "$project" \
    --env-file "$runtime_file" --env-file "$event_file" --env-file "$mirror_file" \
    -f "$base_file" -f "$event_override" -f "$mirror_override" "$@"
}

test "$(hostname)" = "sf-test-server"
test "$(tailscale ip -4)" = "100.64.127.75"
test "$(cat "$repo_dir/DEPLOYMENT_COMMIT")" = "$expected_commit"
test -r "$runtime_file"
test -r "$event_file"
test "$(stat -c '%a' "$event_file")" = "600"

if test "$action" = "stop"; then
  docker rm -f traccar-dev-position-mirror-1 >/dev/null 2>&1 || true
  normal_compose up -d --no-build --pull never traccar
  test -z "$(docker exec traccar-dev-traccar-1 printenv FORWARD_URL 2>/dev/null || true)"
  test "$(docker exec traccar-dev-traccar-1 printenv PROTOCOLS_ENABLE)" = "teltonika,smartcar"
  test -z "$(ss -ltn | grep -E ':5055[[:space:]]' || true)"
  echo "TRACCAR_POSITION_MIRROR_STOPPED"
  exit 0
fi

if test "$action" = "status"; then
  normal_compose ps
  docker ps --filter name=traccar-dev-position-mirror-1 --format '{{.Names}} {{.Status}}'
  exit 0
fi

test -r "$mirror_file"
test "$(stat -c '%a' "$mirror_file")" = "600"
test -n "$(env_value "$mirror_file" TRACCAR_POSITION_MIRROR_APPROVAL_REFERENCE)"
test -n "$(env_value "$mirror_file" TRACCAR_POSITION_MIRROR_DEVICE_IDS)"
case "$(env_value "$mirror_file" TRACCAR_POSITION_MIRROR_IMAGE)" in
  *@sha256:*) ;;
  *) echo "TRACCAR_POSITION_MIRROR_IMAGE must use an immutable sha256 digest" >&2; exit 1 ;;
esac
test "$(env_value "$mirror_file" TRACCAR_POSITION_FORWARD_URL)" = "$expected_position_url"
case "$(env_value "$mirror_file" TRACCAR_POSITION_FORWARD_HEADER)" in
  "Authorization: Bearer "*) ;;
  *) echo "TRACCAR_POSITION_FORWARD_HEADER must be a Bearer authorization header" >&2; exit 1 ;;
esac
mirror_compose config --quiet
test -z "$(ss -ltn | grep -E ':5055[[:space:]]' || true)"

if test "$action" = "preflight"; then
  mirror_compose run --pull never --rm --no-deps position-mirror \
    python3 /app/traccar_position_mirror.py --validate-config
  echo "TRACCAR_POSITION_MIRROR_PREFLIGHT_COMPLETE"
  exit 0
fi

if test "$action" = "dry-run"; then
  test "$(env_value "$mirror_file" TRACCAR_POSITION_MIRROR_DRY_RUN)" = "true"
  mirror_compose run --pull never --rm --no-deps position-mirror \
    python3 /app/traccar_position_mirror.py --once --dry-run
  echo "TRACCAR_POSITION_MIRROR_DRY_RUN_COMPLETE"
  exit 0
fi

test "$(env_value "$mirror_file" TRACCAR_POSITION_MIRROR_DRY_RUN)" = "false"
curl --noproxy '*' -fsS http://100.64.127.75:18082/api/health >/dev/null
curl --noproxy '*' -fsS "$expected_fleet_health" >/dev/null
mirror_compose up -d --no-build --pull never traccar position-mirror

for _ in $(seq 1 90); do
  traccar_health="$(docker inspect traccar-dev-traccar-1 --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  mirror_state="$(docker inspect traccar-dev-position-mirror-1 --format '{{.State.Status}}')"
  mirror_cycle="$(docker logs traccar-dev-position-mirror-1 2>&1 | grep -c '"event":"position_mirror_cycle"' || true)"
  test "$traccar_health" = healthy && test "$mirror_state" = running && test "$mirror_cycle" -gt 0 && break
  sleep 2
done
test "${traccar_health:-}" = healthy
test "${mirror_state:-}" = running
test "${mirror_cycle:-0}" -gt 0
test "$(docker exec traccar-dev-traccar-1 printenv FORWARD_URL)" = "$expected_position_url"
test "$(docker exec traccar-dev-traccar-1 printenv FORWARD_TYPE)" = json
test "$(docker exec traccar-dev-traccar-1 printenv PROTOCOLS_ENABLE)" = "teltonika,smartcar,osmand"
test -z "$(ss -ltn | grep -E ':5055[[:space:]]' || true)"
date -u +%FT%TZ > /data/migrations/traccar-dev/POSITION_MIRROR_ACTIVATED
echo "TRACCAR_POSITION_MIRROR_ACTIVATED"
