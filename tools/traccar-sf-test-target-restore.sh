#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

run_id="${1:?usage: traccar-sf-test-target-restore.sh RUN_ID rehearsal|final EXPECTED_CONFIG_COMMIT EXPECTED_IMAGE_COMMIT EXPECTED_BUNDLE_SHA256 EXPECTED_TRACCAR_DIGEST EXPECTED_POSTGRES_DIGEST}"
mode="${2:?missing mode}"
expected_config_commit="${3:?missing expected config commit}"
expected_image_commit="${4:?missing expected image commit}"
expected_bundle_sha="${5:?missing bundle SHA-256}"
expected_traccar_digest="${6:?missing Traccar digest}"
expected_postgres_digest="${7:?missing PostgreSQL digest}"

case "$run_id" in
  20??????T??????Z) ;;
  *) echo "Invalid run id: $run_id" >&2; exit 2 ;;
esac
case "$mode" in
  rehearsal) project="traccar-dev-rehearsal-${run_id,,}" ;;
  final) project="traccar-dev" ;;
  *) echo "Mode must be rehearsal or final" >&2; exit 2 ;;
esac
[[ "$expected_config_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$expected_image_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$expected_bundle_sha" =~ ^[0-9a-f]{64}$ ]]
[[ "$expected_traccar_digest" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "$expected_postgres_digest" =~ ^sha256:[0-9a-f]{64}$ ]]

repo_dir="/opt/traccar-dev"
compose_file="$repo_dir/docker/compose/sf-test-server.yaml"
runtime_dir="/etc/traccar-dev"
runtime_file="$runtime_dir/runtime.env"
migration_dir="/data/migrations/traccar-dev/$run_id"
evidence_dir="$migration_dir/target-$mode-evidence"
dump_path="$migration_dir/traccar.dump"
media_path="$migration_dir/media.tar.gz"

compose() {
  docker compose -p "$project" --env-file "$runtime_file" \
    -f "$compose_file" "$@"
}

cleanup_on_failure() {
  status=$?
  trap - EXIT
  if test "$status" -ne 0; then
    compose down --remove-orphans >&2 || true
  fi
  exit "$status"
}
trap cleanup_on_failure EXIT

test "$(hostname)" = "sf-test-server"
test "$(tailscale ip -4)" = "100.64.127.75"
test -r "$repo_dir/DEPLOYMENT_COMMIT"
test -r "$repo_dir/DEPLOYMENT_BUNDLE_SHA256"
test "$(cat "$repo_dir/DEPLOYMENT_COMMIT")" = "$expected_config_commit"
test "$(cat "$repo_dir/DEPLOYMENT_BUNDLE_SHA256")" = "$expected_bundle_sha"
test -r "$compose_file"
test -r "$dump_path"
test -r "$media_path"
test -r "$migration_dir/SHA256SUMS"
test -r "$migration_dir/evidence/source-data.psv"
test -r "$migration_dir/evidence/source-media.psv"
test ! -e "$evidence_dir"
test -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")"
test -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$project")"
test -z "$(ss -ltn | grep -E '100[.]64[.]127[.]75:18082[[:space:]]' || true)"

(
  cd "$migration_dir"
  sha256sum -c SHA256SUMS
)
gzip -t "$media_path"

sudo install -d -o ec2-user -g ec2-user -m 0700 "$runtime_dir"
if test ! -e "$runtime_file"; then
  db_password="$(openssl rand -base64 48 | tr -d '\n')"
  {
    printf 'TRACCAR_DB_PASSWORD=%s\n' "$db_password"
    printf 'TRACCAR_IMAGE=ghcr.io/boliu1998/traccar@%s\n' "$expected_traccar_digest"
    printf 'POSTGRES_IMAGE=postgres@%s\n' "$expected_postgres_digest"
  } > "$runtime_file"
  chmod 0600 "$runtime_file"
  unset db_password
fi

test "$(awk -F= '$1=="TRACCAR_IMAGE"{print $2}' "$runtime_file")" = "ghcr.io/boliu1998/traccar@$expected_traccar_digest"
test "$(awk -F= '$1=="POSTGRES_IMAGE"{print $2}' "$runtime_file")" = "postgres@$expected_postgres_digest"
test -n "$(awk -F= '$1=="TRACCAR_DB_PASSWORD"{print $2}' "$runtime_file")"

mkdir -p "$evidence_dir"
chmod 0700 "$evidence_dir"

docker pull "ghcr.io/boliu1998/traccar@$expected_traccar_digest"
docker pull "postgres@$expected_postgres_digest"
test "$(docker image inspect "ghcr.io/boliu1998/traccar@$expected_traccar_digest" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$expected_image_commit"
compose config --quiet
compose up -d --no-build --pull never database

database_container="$(compose ps -q database)"
test -n "$database_container"
for _ in $(seq 1 60); do
  database_health="$(docker inspect "$database_container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  test "$database_health" = "healthy" && break
  sleep 2
done
test "${database_health:-}" = healthy

compose exec -T database pg_restore \
  -U traccar -d traccar --clean --if-exists --no-owner --no-acl --exit-on-error \
  < "$dump_path"

media_volume="${project}_traccar-media"
docker run --rm -i --entrypoint /bin/sh \
  -v "$media_volume":/restore \
  "ghcr.io/boliu1998/traccar@$expected_traccar_digest" \
  -c 'tar -xzf - -C /restore --strip-components=1' < "$media_path"

compose up -d --no-build --pull never traccar
traccar_container="$(compose ps -q traccar)"
test -n "$traccar_container"
for _ in $(seq 1 90); do
  traccar_health="$(docker inspect "$traccar_container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  test "$traccar_health" = healthy && break
  sleep 2
done
test "${traccar_health:-}" = healthy

curl --noproxy '*' -fsS http://100.64.127.75:18082/api/health \
  > "$evidence_dir/api-health.json"
test -z "$(docker inspect "$traccar_container" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^EVENT_FORWARD_' || true)"
test -z "$(ss -ltn | grep -E ':(15027|15262)[[:space:]]' || true)"

compose exec -T database psql -U traccar -d traccar -At \
  > "$evidence_dir/target-data.psv" <<'SQL'
SELECT 'database_size|'||pg_database_size('traccar');
SELECT 'tables|'||count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';
SELECT 'positions|'||count(*) FROM tc_positions;
SELECT 'position_time_min|'||COALESCE(min(fixtime)::text,'') FROM tc_positions;
SELECT 'position_time_max|'||COALESCE(max(fixtime)::text,'') FROM tc_positions;
SELECT 'devices|'||count(*) FROM tc_devices;
SELECT 'users|'||count(*) FROM tc_users;
SELECT 'events|'||count(*) FROM tc_events;
SELECT 'protocol|'||COALESCE(protocol,'')||'|'||count(*) FROM tc_positions GROUP BY protocol ORDER BY count(*) DESC;
SQL

grep -Ev '^database_size[|]' "$migration_dir/evidence/source-data.psv" \
  > "$evidence_dir/source-data-comparable.psv"
grep -Ev '^database_size[|]' "$evidence_dir/target-data.psv" \
  > "$evidence_dir/target-data-comparable.psv"
diff -u "$evidence_dir/source-data-comparable.psv" "$evidence_dir/target-data-comparable.psv"

docker run --rm --entrypoint /bin/sh -v "$media_volume":/media:ro \
  "ghcr.io/boliu1998/traccar@$expected_traccar_digest" \
  -lc "find /media -type f | wc -l; find /media -type f -exec stat -c '%s' {} + | awk '{total += \\$1} END {print total + 0}'" \
  > "$evidence_dir/target-media-raw.txt"
target_media_files="$(sed -n '1p' "$evidence_dir/target-media-raw.txt")"
target_media_bytes="$(awk 'NR==2{print $1}' "$evidence_dir/target-media-raw.txt")"
source_media_files="$(awk -F'|' '$1=="media_files"{print $2}' "$migration_dir/evidence/source-media.psv")"
source_media_bytes="$(awk -F'|' '$1=="media_bytes"{print $2}' "$migration_dir/evidence/source-media.psv")"
test "$target_media_files" = "$source_media_files"
test "$target_media_bytes" = "$source_media_bytes"

compose ps -a > "$evidence_dir/compose-ps.txt"
docker inspect "$traccar_container" \
  --format 'image={{.Image}}|status={{.State.Status}}|health={{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  > "$evidence_dir/traccar-container.txt"
date -u +%FT%TZ > "$evidence_dir/RESTORE_COMPLETE"
trap - EXIT

echo "TRACCAR_TARGET_RESTORE_COMPLETE"
echo "mode=$mode"
echo "project=$project"
cat "$evidence_dir/target-data.psv"
