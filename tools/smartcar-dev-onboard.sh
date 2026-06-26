#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/smartcar-dev-onboard.sh --vehicle-id VEHICLE_ID [--name "Mercedes Smartcar Dev"]

Run on the Traccar dev server. The script prompts for the Smartcar
management token without echoing it, updates /opt/traccar-dev/.env, restarts
dev Traccar, creates/links the Traccar device, and verifies the webhook.
EOF
}

vehicle_id=""
device_name="Mercedes Smartcar Dev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vehicle-id)
      vehicle_id="${2:-}"
      shift 2
      ;;
    --name)
      device_name="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$vehicle_id" ]]; then
  echo "Missing --vehicle-id" >&2
  usage >&2
  exit 2
fi

cd /opt/traccar-dev
if [[ ! -f docker-compose.yml || ! -f .env ]]; then
  echo "Run this on the Traccar dev server in /opt/traccar-dev" >&2
  exit 1
fi

read -rsp "Smartcar Management Token: " token
echo
if [[ -z "$token" ]]; then
  echo "Token is required" >&2
  exit 2
fi

stamp=$(date +%Y%m%d%H%M%S)
cp .env ".env.${stamp}.bak"
sed -i '/^SMARTCAR_MANAGEMENT_TOKEN=/d' .env
printf '\nSMARTCAR_MANAGEMENT_TOKEN=%s\n' "$token" >> .env

docker compose config >/tmp/traccar-dev-compose-check.yml
docker compose up -d traccar

for _ in $(seq 1 36); do
  status=$(docker inspect -f '{{.State.Health.Status}}' traccar-dev-traccar-1 2>/dev/null || true)
  echo "health=$status"
  [[ "$status" == "healthy" ]] && break
  sleep 5
done

if [[ "$(docker inspect -f '{{.State.Health.Status}}' traccar-dev-traccar-1)" != "healthy" ]]; then
  echo "Traccar dev did not become healthy" >&2
  exit 1
fi

docker exec -i traccar-dev-database-1 psql -U traccar -d traccar \
  -v device_name="$device_name" -v vehicle_id="$vehicle_id" -P pager=off <<'SQL'
WITH upserted AS (
  INSERT INTO tc_devices (name, uniqueid, attributes, status, disabled)
  VALUES (:'device_name', :'vehicle_id', '{}', 'offline', false)
  ON CONFLICT (uniqueid) DO UPDATE SET name = EXCLUDED.name
  RETURNING id
), admins AS (
  SELECT id FROM tc_users WHERE administrator = true
)
INSERT INTO tc_user_device (userid, deviceid)
SELECT admins.id, upserted.id FROM admins, upserted
WHERE NOT EXISTS (
  SELECT 1 FROM tc_user_device WHERE userid = admins.id AND deviceid = upserted.id
);

SELECT id, name, uniqueid FROM tc_devices WHERE uniqueid = :'vehicle_id';
SQL

# Restart once after direct DB device creation so Traccar's cache sees the vehicleId.
docker compose restart traccar >/dev/null
for _ in $(seq 1 36); do
  status=$(docker inspect -f '{{.State.Health.Status}}' traccar-dev-traccar-1 2>/dev/null || true)
  echo "health=$status"
  [[ "$status" == "healthy" ]] && break
  sleep 5
done

curl -fsS -i --max-time 15 \
  -H 'Content-Type: application/json' \
  -X POST https://gps.smartfoodiegmbh.eu/dev-smartcar \
  --data-binary '{"eventType":"VERIFY","data":{"challenge":"dev-onboard-check"}}' \
  | sed -n '1,12p'

cat <<EOF

Ready.
Smartcar webhook URL: https://gps.smartfoodiegmbh.eu/dev-smartcar
Traccar dev device uniqueId: $vehicle_id
Next: trigger or wait for Smartcar VEHICLE_STATE, then verify positions for this uniqueId.
EOF
