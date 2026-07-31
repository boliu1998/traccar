#!/usr/bin/env bash

set -euo pipefail

expected_image_commit="${1:?usage: traccar-sf-test-source-rollback.sh EXPECTED_IMAGE_COMMIT EXPECTED_TRACCAR_DIGEST}"
expected_traccar_digest="${2:?missing Traccar digest}"
[[ "$expected_image_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$expected_traccar_digest" =~ ^sha256:[0-9a-f]{64}$ ]]

repo_dir="/opt/traccar-dev"
compose() {
  docker compose --project-directory "$repo_dir" --env-file "$repo_dir/.env" \
    -f "$repo_dir/docker-compose.yml" "$@"
}

test "$(tailscale ip -4)" = "100.86.212.126"
test "$(docker inspect traccar-dev-database-1 --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" = healthy
test "$(docker image inspect "$expected_traccar_digest" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$expected_image_commit"

compose up -d --no-build --pull never traccar
for _ in $(seq 1 90); do
  health="$(docker inspect traccar-dev-traccar-1 --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  test "$health" = healthy && break
  sleep 2
done
test "${health:-}" = healthy
curl --noproxy '*' -fsS http://100.86.212.126:18082/api/health >/dev/null
echo "TRACCAR_SOURCE_ROLLBACK_COMPLETE"
