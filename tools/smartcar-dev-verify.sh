#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/smartcar-dev-verify.sh --vehicle-id VEHICLE_ID

Run on the Traccar dev server. The script checks that dev Traccar is healthy,
the Smartcar webhook verifies, the device exists, and recent smartcar positions
have been stored for the supplied Smartcar vehicleId.
EOF
}

vehicle_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vehicle-id)
      vehicle_id="${2:-}"
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

echo "== Container =="
docker inspect -f 'health={{.State.Health.Status}} started={{.State.StartedAt}}' traccar-dev-traccar-1
docker exec traccar-dev-traccar-1 sh -lc '
  printf "PROTOCOLS_ENABLE=%s\n" "$PROTOCOLS_ENABLE"
  if [ -n "$SMARTCAR_MANAGEMENT_TOKEN" ]; then
    echo "SMARTCAR_MANAGEMENT_TOKEN=set"
  else
    echo "SMARTCAR_MANAGEMENT_TOKEN=missing"
  fi
'

echo
echo "== Webhook VERIFY =="
curl -fsS -i --max-time 15 \
  -H 'Content-Type: application/json' \
  -X POST https://gps.smartfoodiegmbh.eu/dev-smartcar \
  --data-binary '{"eventType":"VERIFY","data":{"challenge":"dev-verify-check"}}' \
  | sed -n '1,12p'

echo
echo "== Device =="
docker exec -i traccar-dev-database-1 psql -U traccar -d traccar \
  -v vehicle_id="$vehicle_id" -P pager=off <<'SQL'
SELECT id, name, uniqueid, status, lastupdate, positionid
FROM tc_devices
WHERE uniqueid = :'vehicle_id';
SQL

echo
echo "== Latest Smartcar Positions =="
docker exec -i traccar-dev-database-1 psql -U traccar -d traccar \
  -v vehicle_id="$vehicle_id" -P pager=off <<'SQL'
SELECT p.id, p.protocol, p.servertime, p.fixtime, p.latitude, p.longitude, p.attributes
FROM tc_positions p
JOIN tc_devices d ON d.id = p.deviceid
WHERE d.uniqueid = :'vehicle_id'
ORDER BY p.id DESC
LIMIT 5;
SQL

echo
echo "== Recent Smartcar Logs =="
docker logs --since 30m traccar-dev-traccar-1 2>&1 \
  | grep -E "smartcar|${vehicle_id}" \
  | tail -80 || true
