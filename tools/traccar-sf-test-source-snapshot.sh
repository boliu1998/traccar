#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

run_id="${1:?usage: traccar-sf-test-source-snapshot.sh RUN_ID rehearsal|final EXPECTED_COMMIT EXPECTED_TRACCAR_DIGEST EXPECTED_POSTGRES_DIGEST}"
mode="${2:?missing mode}"
expected_commit="${3:?missing expected commit}"
expected_traccar_digest="${4:?missing Traccar digest}"
expected_postgres_digest="${5:?missing PostgreSQL digest}"

case "$run_id" in
  20??????T??????Z) ;;
  *) echo "Invalid run id: $run_id" >&2; exit 2 ;;
esac
case "$mode" in
  rehearsal | final) ;;
  *) echo "Mode must be rehearsal or final" >&2; exit 2 ;;
esac
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$expected_traccar_digest" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "$expected_postgres_digest" =~ ^sha256:[0-9a-f]{64}$ ]]

repo_dir="/opt/traccar-dev"
staging_dir="/var/tmp/traccar-dev-$mode-$run_id"
evidence_dir="$staging_dir/evidence"
dump_path="$staging_dir/traccar.dump"
media_path="$staging_dir/media.tar.gz"
traccar_container="traccar-dev-traccar-1"
database_container="traccar-dev-database-1"
traccar_stopped=0

compose() {
  docker compose --project-directory "$repo_dir" --env-file "$repo_dir/.env" \
    -f "$repo_dir/docker-compose.yml" "$@"
}

restart_on_failure() {
  status=$?
  trap - EXIT
  if test "$status" -ne 0 && test "$traccar_stopped" = "1"; then
    compose up -d --no-build --pull never traccar >&2 || true
  fi
  exit "$status"
}
trap restart_on_failure EXIT

test "$(tailscale ip -4)" = "100.86.212.126"
test ! -e "$staging_dir"
test "$(docker inspect "$traccar_container" --format '{{.Image}}')" = "$expected_traccar_digest"
test "$(docker inspect "$database_container" --format '{{.Image}}')" = "$expected_postgres_digest"
test "$(docker inspect "$database_container" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" = healthy
test "$(docker image inspect "$expected_traccar_digest" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$expected_commit"

mkdir -p "$evidence_dir"
chmod 0700 "$staging_dir" "$evidence_dir"

docker image inspect "$expected_traccar_digest" \
  --format 'id={{.Id}}|created={{.Created}}|arch={{.Architecture}}|revision={{index .Config.Labels "org.opencontainers.image.revision"}}|digests={{json .RepoDigests}}' \
  > "$evidence_dir/traccar-image.txt"
docker image inspect "$expected_postgres_digest" \
  --format 'id={{.Id}}|created={{.Created}}|arch={{.Architecture}}|digests={{json .RepoDigests}}' \
  > "$evidence_dir/postgres-image.txt"
docker exec "$traccar_container" sha256sum /opt/traccar/tracker-server.jar \
  > "$evidence_dir/tracker-server-jar.sha256"
awk -F= '$1=="TRACCAR_EVENT_FORWARD_URL"{print "source_event_forward_url|"$2}' \
  "$repo_dir/.env" > "$evidence_dir/source-forward-url.psv"

if test "$mode" = "final"; then
  compose stop -t 60 traccar
  test "$(docker inspect "$traccar_container" --format '{{.State.Running}}')" = false
  traccar_stopped=1
fi

docker exec "$database_container" pg_dump \
  -U traccar -d traccar -Fc --no-owner --no-acl > "$dump_path"
test -s "$dump_path"
docker exec -i "$database_container" pg_restore --list < "$dump_path" \
  > "$evidence_dir/pg-restore-list.txt"
test -s "$evidence_dir/pg-restore-list.txt"

tar -C "$repo_dir" -czf "$media_path" media
gzip -t "$media_path"

docker exec -i "$database_container" psql -U traccar -d traccar -At \
  > "$evidence_dir/source-data.psv" <<'SQL'
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

find "$repo_dir/media" -type f -printf '.' | wc -c \
  | awk '{print "media_files|"$1}' > "$evidence_dir/source-media.psv"
find "$repo_dir/media" -type f -printf '%s\n' \
  | awk '{total += $1} END {print "media_bytes|" total + 0}' \
  >> "$evidence_dir/source-media.psv"

(
  cd "$staging_dir"
  sha256sum traccar.dump media.tar.gz > SHA256SUMS
  stat -c '%n|%s' traccar.dump media.tar.gz > FILE_SIZES
)

if test "$mode" = "final"; then
  date -u +%FT%TZ > "$staging_dir/SOURCE_STOPPED"
  traccar_stopped=0
fi
date -u +%FT%TZ > "$staging_dir/SNAPSHOT_COMPLETE"
trap - EXIT

echo "TRACCAR_SOURCE_SNAPSHOT_COMPLETE"
echo "mode=$mode"
echo "staging_dir=$staging_dir"
cat "$staging_dir/FILE_SIZES"
cat "$staging_dir/SHA256SUMS"
