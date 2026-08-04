#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol


INTERNAL_INGEST_HOST = "traccar"
INTERNAL_INGEST_PORT = 5055


class MirrorError(RuntimeError):
    pass


@dataclass(frozen=True)
class MirrorConfig:
    source_base_url: str
    source_token: str
    source_expected_host: str
    ingest_url: str
    device_ids: frozenset[int]
    state_path: Path
    poll_seconds: int
    lookback_seconds: int
    dry_run: bool
    approval_reference: str

    @classmethod
    def from_environment(cls, environment: Mapping[str, str] | None = None) -> "MirrorConfig":
        env = environment or os.environ
        config = cls(
            source_base_url=env.get("TRACCAR_POSITION_MIRROR_SOURCE_URL", "").strip(),
            source_token=env.get("TRACCAR_POSITION_MIRROR_SOURCE_TOKEN", "").strip(),
            source_expected_host=env.get("TRACCAR_POSITION_MIRROR_SOURCE_HOST", "").strip(),
            ingest_url=env.get("TRACCAR_POSITION_MIRROR_INGEST_URL", "http://traccar:5055/").strip(),
            device_ids=_device_ids(env.get("TRACCAR_POSITION_MIRROR_DEVICE_IDS", "")),
            state_path=Path(env.get("TRACCAR_POSITION_MIRROR_STATE_PATH", "/state/watermarks.json")),
            poll_seconds=_positive_int(env.get("TRACCAR_POSITION_MIRROR_POLL_SECONDS", "10"), "poll seconds"),
            lookback_seconds=_positive_int(
                env.get("TRACCAR_POSITION_MIRROR_LOOKBACK_SECONDS", "60"),
                "lookback seconds",
            ),
            dry_run=_boolean(env.get("TRACCAR_POSITION_MIRROR_DRY_RUN", "true")),
            approval_reference=env.get("TRACCAR_POSITION_MIRROR_APPROVAL_REFERENCE", "").strip(),
        )
        return config.validate()

    def validate(self) -> "MirrorConfig":
        source = urllib.parse.urlparse(self.source_base_url)
        ingest = urllib.parse.urlparse(self.ingest_url)
        if source.scheme != "https":
            raise MirrorError("source URL must use HTTPS")
        if source.username or source.password or source.query or source.fragment:
            raise MirrorError("source URL must not contain credentials, query parameters, or fragments")
        if source.path.rstrip("/") not in {"", "/api"}:
            raise MirrorError("source URL path must be empty or /api")
        if not source.hostname or source.hostname.lower() != self.source_expected_host.lower():
            raise MirrorError("source host does not match the approved host")
        if (
            ingest.scheme != "http"
            or ingest.hostname != INTERNAL_INGEST_HOST
            or ingest.port != INTERNAL_INGEST_PORT
            or ingest.path.rstrip("/")
            or ingest.username
            or ingest.password
            or ingest.query
            or ingest.fragment
        ):
            raise MirrorError("ingest URL must be the internal traccar-dev OsmAnd endpoint")
        if not self.source_token:
            raise MirrorError("source read-only token is required")
        if not self.approval_reference:
            raise MirrorError("approval reference is required before reading production positions")
        if not self.device_ids:
            raise MirrorError("approved device IDs are required before reading production positions")
        if not self.state_path.is_absolute():
            raise MirrorError("state path must be absolute")
        if not 5 <= self.poll_seconds <= 300:
            raise MirrorError("poll seconds must be between 5 and 300")
        if not 10 <= self.lookback_seconds <= 3600:
            raise MirrorError("lookback seconds must be between 10 and 3600")
        return self

    @property
    def source_api_url(self) -> str:
        base = self.source_base_url.rstrip("/")
        return base if base.endswith("/api") else f"{base}/api"


@dataclass(frozen=True)
class MirrorSummary:
    devices: int = 0
    candidates: int = 0
    replayed: int = 0


class Transport(Protocol):
    def get_json(self, url: str, *, headers: Mapping[str, str]) -> Any: ...

    def post_form(self, url: str, *, fields: Mapping[str, str]) -> None: ...


class UrlLibTransport:
    def __init__(self, timeout_seconds: int = 20):
        self.timeout_seconds = timeout_seconds

    def get_json(self, url: str, *, headers: Mapping[str, str]) -> Any:
        payload = self._request(urllib.request.Request(url, headers=dict(headers), method="GET"))
        try:
            return json.loads(payload)
        except (TypeError, ValueError) as exc:
            raise MirrorError("remote response is not valid JSON") from exc

    def post_form(self, url: str, *, fields: Mapping[str, str]) -> None:
        request = urllib.request.Request(
            url,
            data=urllib.parse.urlencode(fields).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        self._request(request)

    def _request(self, request: urllib.request.Request) -> bytes:
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            raise MirrorError(f"remote request failed with HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise MirrorError("remote request failed") from exc


class PositionMirror:
    def __init__(
        self,
        config: MirrorConfig,
        *,
        transport: Transport | None = None,
        clock: Callable[[], datetime] | None = None,
    ):
        self.config = config.validate()
        self.transport = transport or UrlLibTransport()
        self.clock = clock or (lambda: datetime.now(timezone.utc))

    def run_once(self) -> MirrorSummary:
        state = _load_state(self.config.state_path)
        devices = self._fetch_devices()
        devices_by_id = {_required_int(device.get("id"), "device id"): device for device in devices}
        missing_device_ids = self.config.device_ids.difference(devices_by_id)
        if missing_device_ids:
            raise MirrorError("one or more approved devices are not visible to the source token")
        devices = [devices_by_id[device_id] for device_id in sorted(self.config.device_ids)]
        summary = MirrorSummary(devices=len(devices))
        for device in devices:
            device_id = _required_int(device.get("id"), "device id")
            unique_id = str(device.get("uniqueId") or "").strip()
            if not unique_id:
                raise MirrorError(f"device {device_id} is missing uniqueId")
            positions = self._fetch_positions(device_id, state)
            watermark = _device_watermark(state, device_id)
            candidates = sorted(
                (position for position in positions if _required_int(position.get("id"), "position id") > watermark),
                key=lambda position: _required_int(position.get("id"), "position id"),
            )
            for position in candidates:
                _validate_position(position, device_id)
            summary = replace(summary, candidates=summary.candidates + len(candidates))
            if self.config.dry_run:
                continue
            for position in candidates:
                self.transport.post_form(
                    self.config.ingest_url,
                    fields=_osmand_fields(unique_id=unique_id, device_id=device_id, position=position),
                )
                position_id = _required_int(position.get("id"), "position id")
                _set_device_watermark(state, device_id, position_id, str(position.get("fixTime") or ""))
                _save_state(self.config.state_path, state)
                summary = replace(summary, replayed=summary.replayed + 1)
        return summary

    def _fetch_devices(self) -> list[dict[str, Any]]:
        query = urllib.parse.urlencode(
            {"id": sorted(self.config.device_ids), "excludeAttributes": "true"},
            doseq=True,
        )
        payload = self.transport.get_json(
            f"{self.config.source_api_url}/devices?{query}",
            headers=self._source_headers,
        )
        if not isinstance(payload, list) or not all(isinstance(device, dict) for device in payload):
            raise MirrorError("Traccar devices response must be a list of objects")
        return payload

    def _fetch_positions(self, device_id: int, state: Mapping[str, Any]) -> list[dict[str, Any]]:
        saved_fix_time = str(_device_state(state, device_id).get("fix_time") or "")
        query_values: dict[str, Any] = {"deviceId": device_id}
        if saved_fix_time:
            now = self.clock().astimezone(timezone.utc)
            from_time = _parse_datetime(saved_fix_time) - timedelta(seconds=self.config.lookback_seconds)
            query_values.update({"from": _iso_z(from_time), "to": _iso_z(now)})
        query = urllib.parse.urlencode(query_values)
        payload = self.transport.get_json(
            f"{self.config.source_api_url}/positions?{query}",
            headers=self._source_headers,
        )
        if not isinstance(payload, list) or not all(isinstance(position, dict) for position in payload):
            raise MirrorError("Traccar positions response must be a list of objects")
        return payload

    @property
    def _source_headers(self) -> Mapping[str, str]:
        return {"Authorization": f"Bearer {self.config.source_token}", "Accept": "application/json"}


def _load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "devices": {}}
    try:
        payload = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise MirrorError("mirror state is unreadable") from exc
    if payload.get("version") != 1 or not isinstance(payload.get("devices"), dict):
        raise MirrorError("mirror state has an unsupported format")
    return payload


def _save_state(path: Path, state: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as temporary:
            json.dump(state, temporary, sort_keys=True, separators=(",", ":"))
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
    except Exception:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise


def _device_state(state: Mapping[str, Any], device_id: int) -> Mapping[str, Any]:
    return state.get("devices", {}).get(str(device_id), {})


def _device_watermark(state: Mapping[str, Any], device_id: int) -> int:
    return int(_device_state(state, device_id).get("position_id") or 0)


def _set_device_watermark(state: dict[str, Any], device_id: int, position_id: int, fix_time: str) -> None:
    state.setdefault("devices", {})[str(device_id)] = {"position_id": position_id, "fix_time": fix_time}


def _required_int(value: Any, label: str) -> int:
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise MirrorError(f"{label} must be an integer") from exc
    if result <= 0:
        raise MirrorError(f"{label} must be positive")
    return result


def _device_ids(value: str) -> frozenset[int]:
    if not value.strip():
        return frozenset()
    return frozenset(_required_int(item.strip(), "device id") for item in value.split(","))


def _validate_position(position: Mapping[str, Any], device_id: int) -> None:
    if _required_int(position.get("deviceId"), "position device id") != device_id:
        raise MirrorError("Traccar position belongs to a different device")
    fix_time = str(position.get("fixTime") or "")
    if not fix_time:
        raise MirrorError("Traccar position is missing fixTime")
    _parse_datetime(fix_time)
    latitude = _required_finite_float(position.get("latitude"), "latitude")
    longitude = _required_finite_float(position.get("longitude"), "longitude")
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        raise MirrorError("Traccar position coordinates are outside valid ranges")


def _osmand_fields(*, unique_id: str, device_id: int, position: Mapping[str, Any]) -> dict[str, str]:
    position_id = _required_int(position.get("id"), "position id")
    fields = {
        "id": unique_id,
        "timestamp": str(position["fixTime"]),
        "lat": _number_text(position["latitude"], "latitude"),
        "lon": _number_text(position["longitude"], "longitude"),
        "valid": _boolean_text(position.get("valid", True)),
        "mirrorSourceDeviceId": f"traccar:{device_id}",
        "mirrorSourcePositionId": f"traccar:{position_id}",
    }
    for source_key, target_key in (
        ("speed", "speed"),
        ("course", "bearing"),
        ("altitude", "altitude"),
        ("accuracy", "accuracy"),
    ):
        if position.get(source_key) is not None:
            fields[target_key] = _number_text(position[source_key], source_key)
    attributes = position.get("attributes")
    if isinstance(attributes, Mapping):
        for source_key, target_key in (
            ("batteryLevel", "batt"),
            ("hdop", "hdop"),
            ("ignition", "ignition"),
            ("motion", "motion"),
            ("odometer", "odometer"),
            ("sat", "sat"),
            ("totalDistance", "totalDistance"),
        ):
            value = attributes.get(source_key)
            if value is not None:
                fields[target_key] = _field_text(value, source_key)
    return fields


def _required_finite_float(value: Any, label: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise MirrorError(f"{label} must be numeric") from exc
    if not math.isfinite(result):
        raise MirrorError(f"{label} must be finite")
    return result


def _number_text(value: Any, label: str) -> str:
    _required_finite_float(value, label)
    return str(value)


def _boolean_text(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    raise MirrorError("boolean position field must be true or false")


def _field_text(value: Any, label: str) -> str:
    if isinstance(value, bool):
        return _boolean_text(value)
    return _number_text(value, label)


def _parse_datetime(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise MirrorError("saved fix time is invalid") from exc
    if parsed.tzinfo is None:
        raise MirrorError("saved fix time must include a timezone")
    return parsed.astimezone(timezone.utc)


def _iso_z(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _positive_int(value: str, label: str) -> int:
    try:
        result = int(value)
    except ValueError as exc:
        raise MirrorError(f"{label} must be an integer") from exc
    if result <= 0:
        raise MirrorError(f"{label} must be positive")
    return result


def _boolean(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise MirrorError("boolean setting must be true or false")


def _log_summary(summary: MirrorSummary, *, dry_run: bool) -> None:
    print(
        json.dumps(
            {
                "event": "position_mirror_cycle",
                "mode": "dry-run" if dry_run else "live",
                "devices": summary.devices,
                "candidates": summary.candidates,
                "replayed": summary.replayed,
            },
            separators=(",", ":"),
        ),
        flush=True,
    )


def _log_config(config: MirrorConfig) -> None:
    print(
        json.dumps(
            {
                "event": "position_mirror_config_valid",
                "mode": "dry-run" if config.dry_run else "live",
                "device_count": len(config.device_ids),
                "poll_seconds": config.poll_seconds,
                "lookback_seconds": config.lookback_seconds,
            },
            separators=(",", ":"),
        ),
        flush=True,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Replay production Traccar positions into traccar-dev.")
    parser.add_argument("--once", action="store_true", help="run one cycle and exit")
    parser.add_argument("--dry-run", action="store_true", help="override configuration and never write traccar-dev")
    parser.add_argument("--validate-config", action="store_true", help="validate configuration without network access")
    args = parser.parse_args(argv)
    try:
        config = MirrorConfig.from_environment()
        if args.dry_run:
            config = replace(config, dry_run=True).validate()
        if args.validate_config:
            _log_config(config)
            return 0
        mirror = PositionMirror(config)
        while True:
            _log_summary(mirror.run_once(), dry_run=config.dry_run)
            if args.once:
                return 0
            time.sleep(config.poll_seconds)
    except MirrorError as exc:
        print(json.dumps({"event": "position_mirror_error", "message": str(exc)}), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
