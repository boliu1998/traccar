# Traccar Test Environment

Updated: 2026-07-31

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
