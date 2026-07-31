#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

expected_commit="${1:?usage: traccar-sf-test-target-activate.sh EXPECTED_COMMIT teltonika|teltonika-smartcar}"
protocol_scope="${2:?missing protocol scope}"
case "$protocol_scope" in
  teltonika) protocol_override="sf-test-server-device.yaml" ;;
  teltonika-smartcar) protocol_override="sf-test-server-smartcar.yaml" ;;
  *) echo "Protocol scope must be teltonika or teltonika-smartcar" >&2; exit 2 ;;
esac
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]

repo_dir="/opt/traccar-dev"
runtime_file="/etc/traccar-dev/runtime.env"
forward_file="/etc/traccar-dev/forward.env"
base_file="$repo_dir/docker/compose/sf-test-server.yaml"
forward_override="$repo_dir/docker/compose/sf-test-server-forward.yaml"
protocol_file="$repo_dir/docker/compose/$protocol_override"
expected_forward_url="http://sf-test-server.tail056d0a.ts.net/fleet-test/api/v1/gps/traccar/v1/events"
project="traccar-dev"
activated=0

base_compose() {
  docker compose -p "$project" --env-file "$runtime_file" \
    -f "$base_file" "$@"
}

active_compose() {
  docker compose -p "$project" \
    --env-file "$runtime_file" --env-file "$forward_file" \
    -f "$base_file" -f "$protocol_file" -f "$forward_override" "$@"
}

rollback_activation() {
  status=$?
  trap - EXIT
  if test "$status" -ne 0 && test "$activated" = "1"; then
    base_compose up -d --no-build --pull never traccar >&2 || true
  fi
  exit "$status"
}
trap rollback_activation EXIT

test "$(hostname)" = "sf-test-server"
test "$(tailscale ip -4)" = "100.64.127.75"
test "$(cat "$repo_dir/DEPLOYMENT_COMMIT")" = "$expected_commit"
test -r "$runtime_file"
test -r "$forward_file"
test "$(stat -c '%a' "$forward_file")" = "600"
test "$(awk -F= '$1=="TRACCAR_EVENT_FORWARD_URL"{print substr($0,index($0,"=")+1)}' "$forward_file")" = "$expected_forward_url"
test -n "$(awk -F= '$1=="TRACCAR_EVENT_FORWARD_HEADER"{print substr($0,index($0,"=")+1)}' "$forward_file")"

test "$(base_compose ps --status running --services | sort)" = "$(printf 'database\ntraccar')"
test "$(docker inspect traccar-dev-database-1 --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" = healthy
curl --noproxy '*' -fsS http://100.64.127.75:18082/api/health >/dev/null
curl --noproxy '*' -fsS http://sf-test-server.tail056d0a.ts.net/fleet-test/api/v1/health >/dev/null

active_compose config --quiet
activated=1
active_compose up -d --no-build --pull never traccar

for _ in $(seq 1 90); do
  health="$(docker inspect traccar-dev-traccar-1 --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  test "$health" = healthy && break
  sleep 2
done
test "${health:-}" = healthy
test "$(docker exec traccar-dev-traccar-1 printenv EVENT_FORWARD_URL)" = "$expected_forward_url"
test -n "$(docker exec traccar-dev-traccar-1 printenv EVENT_FORWARD_HEADER)"
ss -ltn | grep -E '0[.]0[.]0[.]0:15027[[:space:]]' >/dev/null
if test "$protocol_scope" = "teltonika-smartcar"; then
  ss -ltn | grep -E '0[.]0[.]0[.]0:15262[[:space:]]' >/dev/null
else
  test -z "$(ss -ltn | grep -E ':15262[[:space:]]' || true)"
fi
curl --noproxy '*' -fsS http://100.64.127.75:18082/api/health >/dev/null

date -u +%FT%TZ > "/data/migrations/traccar-dev/ACTIVATED"
trap - EXIT
echo "TRACCAR_TARGET_ACTIVATION_COMPLETE"
echo "protocol_scope=$protocol_scope"
echo "event_forward_url=$expected_forward_url"
