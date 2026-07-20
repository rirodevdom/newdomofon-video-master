#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import json
import os
from pathlib import Path
import time
from typing import Any
from urllib.parse import quote, urlparse

import requests


MANAGED_TOKEN_PREFIXES = ("m1.", "mct1.")
DEFAULT_NEWDOMOFON_HOSTS = (
    "new-video.domofon-37.ru",
    "video-master.domofon-37.ru",
)
DEFAULT_TOKEN_FILE = "/etc/newdomofon-video/smartyard-camera-tokens.json"


@dataclass
class NewDomofonCompatibilityError(RuntimeError):
    message: str
    status_code: int = 502

    def __str__(self) -> str:
        return self.message


def _normalized_hosts() -> set[str]:
    raw = os.getenv("NEWDOMOFON_MEDIA_HOSTS", ",".join(DEFAULT_NEWDOMOFON_HOSTS))
    return {item.strip().lower() for item in raw.split(",") if item.strip()}


def is_newdomofon_url(camera_url: str) -> bool:
    try:
        hostname = (urlparse(str(camera_url)).hostname or "").lower()
    except ValueError:
        return False
    return hostname in _normalized_hosts()


def _load_token_mapping() -> dict[str, Any]:
    inline = os.getenv("NEWDOMOFON_CAMERA_TOKENS_JSON", "").strip()
    if inline:
        try:
            payload = json.loads(inline)
        except json.JSONDecodeError as error:
            raise NewDomofonCompatibilityError(
                f"NEWDOMOFON_CAMERA_TOKENS_JSON is invalid JSON: {error}",
                500,
            ) from error
        if not isinstance(payload, dict):
            raise NewDomofonCompatibilityError(
                "NEWDOMOFON_CAMERA_TOKENS_JSON must contain a JSON object",
                500,
            )
        return payload

    path = Path(os.getenv("NEWDOMOFON_CAMERA_TOKENS_FILE", DEFAULT_TOKEN_FILE))
    if not path.is_file():
        return {}

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise NewDomofonCompatibilityError(
            f"Unable to read NewDomofon camera token mapping: {error}",
            500,
        ) from error
    if not isinstance(payload, dict):
        raise NewDomofonCompatibilityError(
            "NewDomofon camera token mapping must contain a JSON object",
            500,
        )
    return payload


def _mapping_candidates(
    *,
    camera_id: Any = None,
    stream: str | None = None,
    camera_url: str,
) -> list[tuple[str, str]]:
    parsed = urlparse(camera_url)
    path_stream = parsed.path.rstrip("/").split("/")[-1] if parsed.path else ""
    candidates: list[tuple[str, str]] = []

    if camera_id is not None:
        candidates.append(("camera_ids", str(camera_id)))
    if stream:
        candidates.append(("streams", str(stream)))
    if path_stream:
        candidates.append(("streams", path_stream))
    candidates.append(("urls", camera_url.rstrip("/")))
    if parsed.hostname:
        candidates.append(("hosts", parsed.hostname.lower()))
    candidates.append(("default", "*"))
    return candidates


def _mapping_token(
    mapping: dict[str, Any],
    *,
    camera_id: Any = None,
    stream: str | None = None,
    camera_url: str,
) -> str:
    flat_keys = [
        str(camera_id) if camera_id is not None else "",
        str(stream or ""),
        urlparse(camera_url).path.rstrip("/").split("/")[-1],
        camera_url.rstrip("/"),
        "*",
    ]
    for key in flat_keys:
        value = mapping.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()

    for section, key in _mapping_candidates(
        camera_id=camera_id,
        stream=stream,
        camera_url=camera_url,
    ):
        bucket = mapping.get(section)
        if section == "default":
            value = bucket if isinstance(bucket, str) else mapping.get("*")
        elif isinstance(bucket, dict):
            value = bucket.get(key)
        else:
            value = None
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def select_media_token(
    existing_token: Any,
    *,
    camera_url: str,
    camera_id: Any = None,
    stream: str | None = None,
) -> str:
    token = str(existing_token or "").strip()

    if not is_newdomofon_url(camera_url):
        if token.startswith("100"):
            return token
        return f"100{token}"

    if token.startswith(MANAGED_TOKEN_PREFIXES):
        return token

    mapped = _mapping_token(
        _load_token_mapping(),
        camera_id=camera_id,
        stream=stream,
        camera_url=camera_url,
    )
    if mapped.startswith(MANAGED_TOKEN_PREFIXES):
        return mapped

    raise NewDomofonCompatibilityError(
        "NewDomofon camera has no managed token. Configure an m1.* or mct1.* "
        "token in the RBT user video token or in "
        f"{os.getenv('NEWDOMOFON_CAMERA_TOKENS_FILE', DEFAULT_TOKEN_FILE)}.",
        422,
    )


def public_camera_token(
    existing_token: Any,
    *,
    camera_url: str,
    camera_id: Any = None,
    stream: str | None = None,
) -> str:
    if not is_newdomofon_url(camera_url):
        return str(existing_token or "")
    return select_media_token(
        existing_token,
        camera_url=camera_url,
        camera_id=camera_id,
        stream=stream,
    )


def _normalize_ranges(payload: Any, fallback_stream: str) -> list[dict[str, Any]]:
    if isinstance(payload, dict) and isinstance(payload.get("data"), list):
        payload = payload["data"]

    if isinstance(payload, list):
        result: list[dict[str, Any]] = []
        for item in payload:
            if not isinstance(item, dict):
                continue
            ranges = item.get("ranges")
            if not isinstance(ranges, list):
                continue
            result.append({
                "stream": str(item.get("stream") or fallback_stream),
                "ranges": ranges,
            })
        return result

    if isinstance(payload, dict):
        result = []
        for key, value in payload.items():
            if not isinstance(value, dict):
                continue
            from_value = value.get("from")
            to_value = value.get("to")
            if not isinstance(from_value, (int, float)) or not isinstance(to_value, (int, float)):
                continue
            duration = max(0, int(to_value - from_value))
            if duration <= 0:
                continue
            result.append({
                "stream": str(key or fallback_stream),
                "ranges": [{
                    "from": int(from_value),
                    "duration": duration,
                }],
            })
        return result

    return []


def fetch_camera_ranges(
    *,
    camera_url: str,
    existing_token: Any,
    camera_id: Any = None,
    stream: str | None = None,
    from_timestamp: int = 1525186456,
) -> list[dict[str, Any]]:
    token = select_media_token(
        existing_token,
        camera_url=camera_url,
        camera_id=camera_id,
        stream=stream,
    )
    timeout = max(3, int(os.getenv("NEWDOMOFON_MEDIA_TIMEOUT_SECONDS", "20")))

    try:
        response = requests.get(
            f"{camera_url.rstrip('/')}/recording_status.json",
            params={"from": int(from_timestamp), "token": token},
            timeout=timeout,
        )
        response.raise_for_status()
        payload = response.json()
    except requests.RequestException as error:
        status = getattr(getattr(error, "response", None), "status_code", None)
        raise NewDomofonCompatibilityError(
            "Video archive ranges request failed"
            + (f" with HTTP {status}" if status else ""),
            502,
        ) from error
    except ValueError as error:
        raise NewDomofonCompatibilityError(
            "Video archive ranges response is not valid JSON",
            502,
        ) from error

    return _normalize_ranges(payload, str(stream or ""))


def build_camera_export_url(
    *,
    camera_url: str,
    existing_token: Any,
    time_from: datetime,
    time_to: datetime,
    camera_id: Any = None,
    stream: str | None = None,
) -> tuple[str, int]:
    duration = int((time_to - time_from).total_seconds())
    if duration <= 0:
        raise NewDomofonCompatibilityError("Archive export range is empty", 422)
    if duration > 900:
        raise NewDomofonCompatibilityError(
            "Установите интервал скачивания не более 15 минут.",
            403,
        )

    token = select_media_token(
        existing_token,
        camera_url=camera_url,
        camera_id=camera_id,
        stream=stream,
    )
    start = int(time.mktime(time_from.timetuple()))
    url = (
        f"{camera_url.rstrip('/')}/archive-{start}-{duration}.mp4"
        f"?token={quote(token, safe='')}"
    )
    return url, duration


def _rewrite_camera_dict(camera: dict[str, Any]) -> bool:
    url = camera.get("url")
    if not isinstance(url, str) or not is_newdomofon_url(url):
        return False

    camera_id = camera.get("id")
    stream = urlparse(url).path.rstrip("/").split("/")[-1]
    token = public_camera_token(
        camera.get("token"),
        camera_url=url,
        camera_id=camera_id,
        stream=stream,
    )
    if camera.get("token") == token:
        return False
    camera["token"] = token
    return True


def _rewrite_camera_payload(value: Any) -> bool:
    changed = False
    if isinstance(value, list):
        for item in value:
            changed = _rewrite_camera_payload(item) or changed
    elif isinstance(value, dict):
        changed = _rewrite_camera_dict(value) or changed
        for key, item in value.items():
            if key == "token":
                continue
            changed = _rewrite_camera_payload(item) or changed
    return changed


def apply_smartyard_response_compat(response: Any, request: Any) -> Any:
    path = str(getattr(request, "path", "") or "")
    if "/cctv/" not in path:
        return response

    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "POST,OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = (
        "Authorization,Content-Type,Range,X-Requested-With"
    )
    response.headers["Access-Control-Expose-Headers"] = (
        "Content-Length,Content-Range,Content-Disposition"
    )
    response.headers["Access-Control-Max-Age"] = "600"

    try:
        payload = response.get_json(silent=True)
    except Exception:
        payload = None

    if payload is not None and _rewrite_camera_payload(payload):
        encoded = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        response.set_data(encoded)
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        response.headers["Content-Length"] = str(len(encoded))

    return response
