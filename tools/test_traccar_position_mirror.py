#!/usr/bin/env python3

from contextlib import redirect_stdout
import io
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from unittest.mock import patch

from traccar_position_mirror import MirrorConfig, MirrorError, PositionMirror, main


class FakeTransport:
    def __init__(self, *, positions=None):
        self.positions = positions or []
        self.gets = []
        self.posts = []

    def get_json(self, url, *, headers):
        self.gets.append((url, headers))
        parsed = urlparse(url)
        if parsed.path.endswith("/api/devices"):
            device_ids = set(parse_qs(parsed.query).get("id", []))
            return (
                [{"id": 501, "uniqueId": "GPS-001", "name": "VAN-01"}]
                if "501" in device_ids
                else []
            )
        return list(self.positions)

    def post_form(self, url, *, fields):
        self.posts.append((url, fields))


class FailingTransport(FakeTransport):
    def post_form(self, url, *, fields):
        super().post_form(url, fields=fields)
        raise MirrorError("traccar-dev ingest failed")


def position(position_id, fix_time="2026-08-04T10:00:00Z"):
    return {
        "id": position_id,
        "deviceId": 501,
        "fixTime": fix_time,
        "serverTime": fix_time,
        "valid": True,
        "latitude": 48.2,
        "longitude": 11.6,
        "speed": 12.5,
        "course": 180.0,
        "altitude": 520.0,
        "accuracy": 4.0,
        "attributes": {"batteryLevel": 78, "ignition": True, "sat": 11},
    }


class PositionMirrorTest(unittest.TestCase):
    def config(self, state_path, *, dry_run=False):
        return MirrorConfig(
            source_base_url="https://traccar-production.example",
            source_token="source-read-only-token",
            source_expected_host="traccar-production.example",
            ingest_url="http://traccar:5055/",
            device_ids=frozenset({501}),
            state_path=Path(state_path),
            poll_seconds=10,
            lookback_seconds=60,
            dry_run=dry_run,
            approval_reference="unit-test-approval",
        )

    def test_config_rejects_insecure_or_unapproved_live_connections(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            base = self.config(Path(temp_dir) / "state.json")

            with self.assertRaisesRegex(MirrorError, "source URL must use HTTPS"):
                MirrorConfig(**{**base.__dict__, "source_base_url": "http://traccar-production.example"}).validate()
            with self.assertRaisesRegex(MirrorError, "source host"):
                MirrorConfig(**{**base.__dict__, "source_expected_host": "other.example"}).validate()
            with self.assertRaisesRegex(MirrorError, "internal traccar-dev OsmAnd"):
                MirrorConfig(**{**base.__dict__, "ingest_url": "http://example.com:5055/"}).validate()
            with self.assertRaisesRegex(MirrorError, "internal traccar-dev OsmAnd"):
                MirrorConfig(**{**base.__dict__, "ingest_url": "http://traccar:8082/"}).validate()
            with self.assertRaisesRegex(MirrorError, "approval reference"):
                MirrorConfig(**{**base.__dict__, "approval_reference": ""}).validate()
            with self.assertRaisesRegex(MirrorError, "approved device IDs"):
                MirrorConfig(**{**base.__dict__, "device_ids": frozenset()}).validate()
            dry_run = MirrorConfig(**{**base.__dict__, "dry_run": True})
            with self.assertRaisesRegex(MirrorError, "approval reference"):
                MirrorConfig(**{**dry_run.__dict__, "approval_reference": ""}).validate()

    def test_live_cycle_replays_each_new_position_once_into_traccar_dev_and_persists_watermark(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "state.json"
            transport = FakeTransport(positions=[position(9100), position(9101, "2026-08-04T10:00:10Z")])
            mirror = PositionMirror(
                self.config(state_path),
                transport=transport,
                clock=lambda: datetime(2026, 8, 4, 10, 0, 20, tzinfo=timezone.utc),
            )

            first = mirror.run_once()
            second = mirror.run_once()

            self.assertEqual(first.replayed, 2)
            self.assertEqual(second.replayed, 0)
            self.assertEqual(len(transport.posts), 2)
            self.assertIn("id=501", transport.gets[0][0])
            self.assertIn("excludeAttributes=true", transport.gets[0][0])
            self.assertEqual(parse_qs(urlparse(transport.gets[1][0]).query), {"deviceId": ["501"]})
            self.assertEqual(parse_qs(urlparse(transport.gets[3][0]).query)["from"], ["2026-08-04T09:59:10Z"])
            self.assertEqual(
                transport.posts[0],
                (
                    "http://traccar:5055/",
                    {
                        "id": "GPS-001",
                        "timestamp": "2026-08-04T10:00:00Z",
                        "lat": "48.2",
                        "lon": "11.6",
                        "valid": "true",
                        "speed": "12.5",
                        "bearing": "180.0",
                        "altitude": "520.0",
                        "accuracy": "4.0",
                        "batt": "78",
                        "ignition": "true",
                        "sat": "11",
                        "mirrorSourceDeviceId": "traccar:501",
                        "mirrorSourcePositionId": "traccar:9100",
                    },
                ),
            )
            self.assertEqual(json.loads(state_path.read_text())["devices"]["501"]["position_id"], 9101)

    def test_dry_run_never_posts_or_advances_watermark(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "state.json"
            transport = FakeTransport(positions=[position(9100)])
            mirror = PositionMirror(
                self.config(state_path, dry_run=True),
                transport=transport,
                clock=lambda: datetime(2026, 8, 4, 10, 0, 20, tzinfo=timezone.utc),
            )

            summary = mirror.run_once()

            self.assertEqual(summary.candidates, 1)
            self.assertEqual(summary.replayed, 0)
            self.assertEqual(transport.posts, [])
            self.assertFalse(state_path.exists())

    def test_failed_traccar_dev_ingest_does_not_advance_watermark(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "state.json"
            transport = FailingTransport(positions=[position(9100)])
            mirror = PositionMirror(
                self.config(state_path),
                transport=transport,
                clock=lambda: datetime(2026, 8, 4, 10, 0, 20, tzinfo=timezone.utc),
            )

            with self.assertRaisesRegex(MirrorError, "ingest failed"):
                mirror.run_once()

            self.assertFalse(state_path.exists())

    def test_approved_device_must_be_visible_to_read_only_token(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "state.json"
            config = MirrorConfig(**{**self.config(state_path).__dict__, "device_ids": frozenset({999})})
            mirror = PositionMirror(config, transport=FakeTransport())

            with self.assertRaisesRegex(MirrorError, "not visible"):
                mirror.run_once()

            self.assertFalse(state_path.exists())

    def test_position_for_another_device_is_rejected_before_forwarding(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "state.json"
            mismatched = {**position(9100), "deviceId": 999}
            transport = FakeTransport(positions=[mismatched])
            mirror = PositionMirror(
                self.config(state_path),
                transport=transport,
                clock=lambda: datetime(2026, 8, 4, 10, 0, 20, tzinfo=timezone.utc),
            )

            with self.assertRaisesRegex(MirrorError, "different device"):
                mirror.run_once()

            self.assertEqual(transport.posts, [])
            self.assertFalse(state_path.exists())

    def test_test_environment_override_is_isolated_and_not_enabled_by_default(self):
        repository = Path(__file__).resolve().parents[1]
        base = (repository / "docker/compose/sf-test-server.yaml").read_text()
        override = (repository / "docker/compose/sf-test-server-position-mirror.yaml").read_text()

        self.assertNotIn("position-mirror", base)
        self.assertIn("position-mirror:", override)
        self.assertIn("read_only: true", override)
        self.assertIn("no-new-privileges:true", override)
        self.assertIn("cap_drop:", override)
        self.assertIn("- ALL", override)
        self.assertIn("TRACCAR_POSITION_MIRROR_DRY_RUN", override)
        self.assertIn("TRACCAR_POSITION_MIRROR_DEVICE_IDS", override)
        self.assertIn("TRACCAR_POSITION_MIRROR_INGEST_URL: http://traccar:5055/", override)
        self.assertIn("PROTOCOLS_ENABLE: teltonika,smartcar,osmand", override)
        self.assertIn("FORWARD_TYPE: json", override)
        self.assertIn("FORWARD_URL:", override)
        self.assertIn("FORWARD_HEADER:", override)
        self.assertIn("traccar_position_mirror.py:/app/traccar_position_mirror.py:ro", override)
        self.assertNotIn('"5055:', override)
        self.assertNotIn("TRACCAR_POSITION_MIRROR_TARGET_SECRET", override)

    def test_activation_script_requires_approval_and_has_explicit_rollback(self):
        repository = Path(__file__).resolve().parents[1]
        script = (repository / "tools/traccar-sf-test-position-mirror.sh").read_text()

        self.assertIn('test "$(hostname)" = "sf-test-server"', script)
        self.assertIn("TRACCAR_POSITION_MIRROR_APPROVAL_REFERENCE", script)
        self.assertIn("TRACCAR_POSITION_MIRROR_DEVICE_IDS", script)
        self.assertIn("TRACCAR_POSITION_MIRROR_DRY_RUN", script)
        self.assertIn("@sha256:", script)
        self.assertIn("--validate-config", script)
        self.assertIn('"event":"position_mirror_cycle"', script)
        self.assertIn("docker rm -f traccar-dev-position-mirror-1", script)
        self.assertIn("normal_compose up -d --no-build --pull never traccar", script)
        self.assertIn("test -z", script)
        self.assertIn(":5055", script)

        example = (repository / "docker/compose/sf-test-server-position-mirror.env.example").read_text()
        self.assertIn("TRACCAR_POSITION_MIRROR_DRY_RUN=true", example)
        self.assertIn("<approved-read-only-token>", example)
        self.assertIn("<fleet-test-position-secret>", example)

    def test_validate_config_does_not_make_network_requests(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            environment = {
                "TRACCAR_POSITION_MIRROR_SOURCE_URL": "https://traccar-production.example",
                "TRACCAR_POSITION_MIRROR_SOURCE_TOKEN": "source-read-only-token",
                "TRACCAR_POSITION_MIRROR_SOURCE_HOST": "traccar-production.example",
                "TRACCAR_POSITION_MIRROR_DEVICE_IDS": "501",
                "TRACCAR_POSITION_MIRROR_STATE_PATH": str(Path(temp_dir) / "state.json"),
                "TRACCAR_POSITION_MIRROR_APPROVAL_REFERENCE": "unit-test-approval",
            }
            with patch.dict(os.environ, environment, clear=True):
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(main(["--validate-config"]), 0)
                self.assertIn('"event":"position_mirror_config_valid"', output.getvalue())


if __name__ == "__main__":
    unittest.main()
