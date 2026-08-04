# Traccar Test Environment

Updated: 2026-08-04

## Migration State

`traccar-dev` moved to `SF-test-server` on 2026-07-31 at 12:42 UTC. Final run
`20260731T123951Z` restored the PostgreSQL database and media, verified the
private Web/API, and changed event forwarding from production Fleet to
Fleet-test. The target runtime is authoritative.

The old Traccar application is stopped. Its PostgreSQL container, data
directory, compose files, and final logical dump remain intact for rollback.
No GPS device endpoint was cut over because this test environment has no real
GPS device in scope.

## Target Identity And Endpoints

| Item | Value |
| --- | --- |
| EC2 name | `SF-test-server` |
| Tailscale hostname | `sf-test-server.tail056d0a.ts.net` |
| Tailscale IPv4 fallback | `100.64.127.75` |
| Public EIP | `52.57.169.208` |
| Server directory | `/opt/traccar-dev` |
| Private Web/API | `https://sf-test-server.tail056d0a.ts.net:18082` |
| Host-only Web/API upstream | `http://127.0.0.1:18083` |
| Teltonika device endpoint, when explicitly enabled | `52.57.169.208:15027/tcp` |
| Smartcar protocol host port, when explicitly enabled | `52.57.169.208:15262/tcp` |
| Event-forward target | `https://sf-test-server.tail056d0a.ts.net/fleet-test/api/v1/gps/traccar/v1/events` |

The HTTPS Web/API port is private to Tailscale and terminates TLS at host
Nginx. The Traccar container binds its HTTP Web/API only to host loopback
`127.0.0.1:18083`. Only protocol ports that are proven to be needed may be
allowed by the EC2 Security Group.

The 2026-07-31 final cutover has no real GPS device in scope. Both `15027` and
`15262` remain unpublished and blocked; a later hardware test must request a
separate device-port activation.

## Migration Safety

- Restore PostgreSQL with a logical dump; do not copy a live PostgreSQL data
  directory.
- Copy `media` and only the logs needed for migration evidence.
- Start the target with event forwarding disabled.
- Replace the current production Fleet event-forward URL with Fleet-test before
  enabling forwarding.
- Publish only Teltonika `5027 -> 15027` and, if still required, Smartcar
  `5262 -> 15262`; do not publish the old `15000-15500` range.
- Change test-device endpoints only during the final cutover window.
- Keep the old runtime stopped but intact during the rollback period.

The base compose file intentionally publishes only the private Web/API port and
does not define any event-forward environment variable. Traccar treats an empty
`EVENT_FORWARD_URL` environment variable as configured, so an empty value is
not a safe way to disable forwarding.

The deployment record tracks the config-bundle commit separately from the
immutable Traccar image revision. A migration may preserve an already-approved
image built from an earlier `origin/dev` commit while deploying newer
environment-only compose and migration tooling from the current `origin/dev`.

Use these overrides only after the corresponding final-cutover gate:

- `sf-test-server-device.yaml`: expose the Teltonika test endpoint.
- `sf-test-server-forward.yaml`: enable forwarding to the approved Fleet-test
  URL and header.
- `sf-test-server-smartcar.yaml`: additionally expose Smartcar after its need
  is explicitly confirmed.

## Production Position Replay Into The Test Stack

The approved architecture for production-like live-position testing is:

```text
production Traccar (read-only API)
  -> position-mirror adapter in the test stack
  -> traccar-dev internal OsmAnd endpoint
  -> traccar-dev native JSON position forwarding
  -> Fleet-test position intake
```

This path does not change Traccar Java code. The adapter is a separate service
defined only in `sf-test-server-position-mirror.yaml`, so the base deployment
keeps it disabled. It polls only explicitly approved production device IDs,
replays the original fix time, coordinates, validity, speed, course, altitude,
accuracy, and selected telemetry attributes, and advances a persistent
per-device watermark only after traccar-dev accepts the position.
On first start it requests the latest position for each approved device so an
inactive vehicle can still appear as offline at its last real location. Later
cycles use the saved fix time with a configurable overlap to cover late points.

The OsmAnd listener is reachable only as `http://traccar:5055/` inside the
Compose network. Port `5055` must never be published on the host or opened in
the EC2 Security Group. The adapter has no Fleet-test credential and cannot
send directly to Fleet-test. Only traccar-dev holds the position-forward
credential and uses its built-in `FORWARD_TYPE=json`, `FORWARD_URL`, and
`FORWARD_HEADER` settings.

The production API credential must be read-only, limited to the approved
devices, and allowed to read position reports. Source device `uniqueId` values
must already exist in traccar-dev, and
the corresponding traccar-dev devices must be mapped to vehicles in Fleet-test.
An unknown device makes the internal OsmAnd request fail, so the adapter does
not advance its watermark.

This flow does not read from or write to S3. S3 remains production-only. It
also performs no write against production Traccar; all writes are confined to
traccar-dev and Fleet-test.

### Activation Gate

Architecture approval alone does not authorize a production read. Before even
a dry-run is connected to production Traccar, record explicit human approval
for all of the following:

- source code line and exact config-bundle commit;
- production Traccar HTTPS host;
- read-only token scope and exact production device IDs;
- test target `traccar-dev` and Fleet-test intake URL;
- pinned adapter image digest;
- polling interval, lookback window, and approval reference;
- one-time validation or continuously running scope;
- rollback owner and stop command.

Do not store tokens or Fleet-test secrets in Git. Keep them in a root-owned
mode-`600` environment file on `SF-test-server`; use
`sf-test-server-position-mirror.env.example` only as the placeholder template.
The adapter refuses to start without an approval reference and a non-empty
device allowlist. Dry-run has the same requirements because it still reads
production positions.

After the approved config bundle and mode-`600` environment file are present,
use the guarded operations script with the exact deployed commit:

```bash
tools/traccar-sf-test-position-mirror.sh EXPECTED_COMMIT preflight
tools/traccar-sf-test-position-mirror.sh EXPECTED_COMMIT dry-run
tools/traccar-sf-test-position-mirror.sh EXPECTED_COMMIT activate
tools/traccar-sf-test-position-mirror.sh EXPECTED_COMMIT status
tools/traccar-sf-test-position-mirror.sh EXPECTED_COMMIT stop
```

`preflight` is offline configuration validation. `dry-run` performs the
approved production read but writes nothing. `activate` starts continuous
replay. `stop` removes the adapter container and recreates traccar-dev without
the internal OsmAnd listener or position-forward settings.

### Pre-activation Validation

Before live mode, validate all of these with placeholder or approved test data:

1. Python unit tests pass for conversion, allowlisting, watermarks, dry-run,
   and failed-ingest recovery.
2. The base and position-mirror Compose files render successfully together.
3. Traccar's OsmAnd decoder and position-forwarder tests pass under Java 21.
4. Each approved `uniqueId` exists in traccar-dev and maps to exactly one
   Fleet-test vehicle.
5. Dry-run candidate counts match the approved device scope and reveal no
   coordinates or secrets in logs.
6. A single approved live position appears first in traccar-dev and then in
   Fleet-test before continuous mode is allowed.

### Rollback

Stop and remove the `position-mirror` service, then recreate traccar-dev without
`sf-test-server-position-mirror.yaml`. This removes the internal OsmAnd listener
and the position `FORWARD_*` settings while leaving the normal private Web/API
and event forwarding unchanged. The adapter watermark volume and already
written test positions remain intact for audit; deleting them is a separate,
explicit operation.

Traccar also supports direct production position forwarding, but that option is
not selected because it bypasses traccar-dev and does not exercise the required
test data path.
