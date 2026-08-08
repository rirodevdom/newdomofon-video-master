#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "v312-hikvision-unified-camera-ui"
LEASE_MARKER = "v312-hikvision-unified-camera-viewer-lease"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1)


def patch_app(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = text.replace('        <v-list-item prepend-icon="mdi-video-wireless" title="Hikvision-каналы" to="/hikvision" />\n', '')
    path.write_text(text, encoding="utf-8")


def patch_router(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = text.replace("import HikvisionChannelsView from './views/HikvisionChannelsView.vue';\n", '')
    text = text.replace("    { path: '/hikvision', component: HikvisionChannelsView, name: 'hikvision-channels' },\n", "    { path: '/hikvision', redirect: '/cameras' },\n")
    # Keep the old detail URL as a hidden compatibility route for saved bookmarks.
    # New navigation always uses /cameras/:cameraId and the ordinary PlayerView.
    path.write_text(text, encoding="utf-8")


def patch_cameras_view(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return

    old = r'''function cameraProtocolTitle(camera: any) {
  return camera.is_onvif ? 'ONVIF' : 'RTSP';
}

function cameraProtocolColor(camera: any) {
  return camera.is_onvif ? 'indigo' : 'blue';
}'''
    new = r'''// v312-hikvision-unified-camera-ui
function cameraProtocolTitle(camera: any) {
  if (camera.device_connection_type === 'HIKVISION') return 'HIKVISION';
  return camera.is_onvif ? 'ONVIF' : 'RTSP';
}

function cameraProtocolColor(camera: any) {
  if (camera.device_connection_type === 'HIKVISION') return 'deep-purple';
  return camera.is_onvif ? 'indigo' : 'blue';
}'''
    text = replace_once(text, old, new, "Hikvision protocol chip in ordinary camera list")
    path.write_text(text, encoding="utf-8")


def patch_player(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "function mediaApiPath" in text and LEASE_MARKER in text:
        return

    computed_anchor = r'''const cameraId = computed(() => String(route.params.id || ''));
const tokenlessLiveUrl = computed(() => camera.value?.stream_name ? `/cameras/${camera.value.stream_name}/live.m3u8` : '—');
const tokenlessArchiveUrl = computed(() => camera.value?.stream_name ? `/cameras/${camera.value.stream_name}/archive.m3u8` : '—');'''
    computed_new = r'''const cameraId = computed(() => String(route.params.id || ''));
const hikvisionChannelId = computed(() => String(camera.value?.hikvision_channel_external_id || ''));
const isHikvision = computed(() => camera.value?.device_connection_type === 'HIKVISION' && Boolean(hikvisionChannelId.value));
const tokenlessLiveUrl = computed(() => camera.value?.stream_name ? `/cameras/${camera.value.stream_name}/live.m3u8` : '—');
const tokenlessArchiveUrl = computed(() => camera.value?.stream_name ? `/cameras/${camera.value.stream_name}/archive.m3u8` : '—');
const cameraArchiveLabel = computed(() => isHikvision.value
  ? (camera.value?.archive_storage === 'device' ? 'Hikvision / NVR' : 'Hikvision-node')
  : 'локальный архив Node');

// v312-hikvision-unified-camera-ui
function mediaApiPath(suffix: string): string {
  const clean = String(suffix || '').replace(/^\/+/, '');
  if (isHikvision.value) {
    return `/hikvision-player/${encodeURIComponent(hikvisionChannelId.value)}/${clean}`;
  }
  return `/player/${encodeURIComponent(cameraId.value)}/${clean}`;
}'''
    if "function mediaApiPath" not in text:
        text = replace_once(text, computed_anchor, computed_new, "unified camera player transport helper")

    lease_anchor = "let archiveSeekAbortController: AbortController | null = null;\n"
    lease_block = lease_anchor + r'''// v312-hikvision-unified-camera-viewer-lease
const archiveViewerId = globalThis.crypto?.randomUUID?.()
  || `hik-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
let archiveViewerChannelId = '';
'''
    if LEASE_MARKER not in text:
        text = replace_once(text, lease_anchor, lease_block, "ordinary PlayerView stable Hikvision viewer id")

    text = replace_once(
        text,
        "<div class=\"mb-2\"><strong>Хранение:</strong> локальный архив Node</div>",
        "<div class=\"mb-2\"><strong>Хранение:</strong> {{ cameraArchiveLabel }}</div>",
        "unified camera storage label",
    )
    text = replace_once(
        text,
        "    const { data } = await api.get(`/player/${encodeURIComponent(cameraId.value)}/status`);",
        "    const { data } = await api.get(mediaApiPath('status'));",
        "unified camera status endpoint",
    )
    text = replace_once(
        text,
        "    const ranges = await api.get(`/player/${encodeURIComponent(id)}/archive/ranges`, {\n      params: { start, end, source: 'node' }\n    });",
        "    const ranges = await api.get(mediaApiPath('archive/ranges'), {\n      params: isHikvision.value ? { start, end } : { start, end, source: 'node' }\n    });",
        "unified camera archive ranges endpoint",
    )
    text = replace_once(
        text,
        "        const live = await api.get(`/player/${encodeURIComponent(id)}/live`);",
        "        const live = await api.get(mediaApiPath('live'));",
        "unified camera live endpoint",
    )
    text = replace_once(
        text,
        "                const archive = await api.get(`/player/${encodeURIComponent(id)}/archive`, {\n                  params: {\n                    start: new Date(effectiveStartMs).toISOString(),\n                    end: new Date(effectiveEndMs).toISOString(),\n                    source: 'node'\n                  },",
        "                const archive = await api.get(mediaApiPath('archive'), {\n                  params: isHikvision.value ? {\n                    start: new Date(effectiveStartMs).toISOString(),\n                    end: new Date(effectiveEndMs).toISOString(),\n                    viewer_id: archiveViewerId\n                  } : {\n                    start: new Date(effectiveStartMs).toISOString(),\n                    end: new Date(effectiveEndMs).toISOString(),\n                    source: 'node'\n                  },",
        "unified camera archive playback endpoint",
    )
    text = replace_once(
        text,
        "              const events = await api.get(`/cameras/${encodeURIComponent(id)}/events`, {",
        "              const events = await api.get(isHikvision.value\n                ? mediaApiPath('events')\n                : `/cameras/${encodeURIComponent(id)}/events`, {",
        "unified camera event endpoint",
    )
    text = replace_once(
        text,
        "              const result = await api.get(`/player/${encodeURIComponent(id)}/export`, {\n                params: { start, end, source: 'node' }\n              });",
        "              const result = await api.get(mediaApiPath('export'), {\n                params: isHikvision.value ? { start, end } : { start, end, source: 'node' }\n              });",
        "unified camera export endpoint",
    )

    old_destroy = r'''function destroyPlayer() {
  archiveSeekGeneration += 1;
  archiveSeekAbortController?.abort();
  archiveSeekAbortController = null;
  archivePreparing.value = false;
  player?.destroy();
  player = null;
  if (playerRoot.value) playerRoot.value.innerHTML = '';
}'''
    new_destroy = r'''function destroyPlayer() {
  const releaseChannelId = archiveViewerChannelId;
  archiveViewerChannelId = '';
  if (releaseChannelId) {
    void api.post(`/hikvision-player/${encodeURIComponent(releaseChannelId)}/archive/release`, {
      viewer_id: archiveViewerId
    }).catch(() => undefined);
  }
  archiveSeekGeneration += 1;
  archiveSeekAbortController?.abort();
  archiveSeekAbortController = null;
  archivePreparing.value = false;
  player?.destroy();
  player = null;
  if (playerRoot.value) playerRoot.value.innerHTML = '';
}'''
    if "releaseChannelId = archiveViewerChannelId" not in text:
        text = replace_once(text, old_destroy, new_destroy, "release Hikvision viewer from ordinary PlayerView")

    ownership_anchor = "  destroyPlayer();\n\n  const nextPlayer = sdk.create({"
    ownership_new = "  destroyPlayer();\n  archiveViewerChannelId = isHikvision.value ? hikvisionChannelId.value : '';\n\n  const nextPlayer = sdk.create({"
    if "archiveViewerChannelId = isHikvision.value" not in text:
        text = replace_once(text, ownership_anchor, ownership_new, "ordinary PlayerView Hikvision lease ownership")

    for required in (
        MARKER,
        LEASE_MARKER,
        "mediaApiPath('live')",
        "mediaApiPath('archive')",
        "mediaApiPath('events')",
        "viewer_id: archiveViewerId",
        "archive/release",
    ):
        if required not in text:
            raise RuntimeError(f"unified camera player marker missing: {required}")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()

    patch_app(root / "frontend/src/App.vue")
    patch_router(root / "frontend/src/router.ts")
    patch_cameras_view(root / "frontend/src/views/CamerasView.vue")
    patch_player(root / "frontend/src/views/PlayerView.vue")

    print("Hikvision cameras now use the ordinary Cameras list and ordinary camera PlayerView")
    print("The separate Hikvision channels navigation entry is removed")
    print("Ordinary PlayerView now owns and releases Hikvision archive viewer leases")


if __name__ == "__main__":
    main()
