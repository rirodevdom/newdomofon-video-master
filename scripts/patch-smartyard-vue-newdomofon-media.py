#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
import shutil


MARKER = "NEWDOMOFON_MEDIA_COMPAT_V1"


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1), True


def patch_player(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    old_preview = '''    generatePreview = (): void => {
        const {url, token} = this.camera;
        this.preview = `${url}/preview.mp4?token=${token}`;
        this.setPreview();
    };
'''
    new_preview = f'''    // {MARKER}: request a timestamp thumbnail instead of an autoplaying live clip.
    generatePreview = (): void => {{
        const {{url, token}} = this.camera;
        const timestamp = Math.floor(Date.now() / 1000);
        this.preview = `${{url.replace(/\\/+$/, "")}}/${{timestamp}}-preview.mp4?token=${{encodeURIComponent(token || "")}}`;
        this.setPreview();
    }};
'''
    text, did = replace_once(text, old_preview, new_preview, "Flussonic preview URL")
    changed = changed or did

    old_stream = '''        this.stream = hlsMode === "fmp4"
            ? `${url}/index${time}.fmp4.m3u8?token=${token}`
            : `${url}/index${time}.m3u8?token=${token}`;
'''
    new_stream = '''        const safeUrl = url.replace(/\/+$/, "");
        const safeToken = encodeURIComponent(token || "");
        this.stream = hlsMode === "fmp4"
            ? `${safeUrl}/index${time}.fmp4.m3u8?token=${safeToken}`
            : `${safeUrl}/index${time}.m3u8?token=${safeToken}`;
'''
    text, did = replace_once(text, old_stream, new_stream, "Flussonic stream token encoding")
    changed = changed or did

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_video_card(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    old = '''    <video
        autoplay
        ref="previewElement"
'''
    new = f'''    <video
        autoplay
        muted
        playsinline
        preload="metadata"
        data-newdomofon-media="{MARKER}"
        ref="previewElement"
'''
    text, changed = replace_once(text, old, new, "VideoCard muted preview")
    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_video_modal(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    old = '      <video ref="previewElement" class="video-preview" v-on:canplay="onCanPlay"/>'
    new = (
        '      <video ref="previewElement" class="video-preview" muted playsinline '
        f'preload="metadata" data-newdomofon-media="{MARKER}" v-on:canplay="onCanPlay"/>'
    )
    text, changed = replace_once(text, old, new, "VideoModal muted preview")
    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_ranges(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    old_direct = '''    const getDmRanges = () => {
        axios.get(`${camera.url}/recording_status.json`)
            .then(res => {
                streams.value = Object.keys(res.data).map(key => ({
                        stream: camera.url,
                        ranges: [{
                            from: res.data[key].from,
                            duration: res.data[key].to - res.data[key].from,
                        }]
                    })
                )
            })
    }
'''
    new_direct = f'''    // {MARKER}: managed camera links are self-contained and do not require
    // a SmartYard subscriber session for archive range discovery.
    const managedCamera = /^m(?:1|ct1)\\./.test(String(camera.token || ""));

    const getDirectRanges = () => {{
        const baseUrl = camera.url.replace(/\\/+$/, "");
        axios.get(`${{baseUrl}}/recording_status.json`, {{
            params: {{token: camera.token}},
        }})
            .then(res => {{
                if (Array.isArray(res.data)) {{
                    streams.value = res.data as Stream[];
                    return;
                }}

                const payload = (res.data || {{}}) as Record<string, {{from: number; to: number}}>;
                streams.value = Object.keys(payload).map(key => ({{
                    stream: key || camera.url,
                    ranges: [{{
                        from: payload[key].from,
                        duration: payload[key].to - payload[key].from,
                    }}]
                }}));
            }})
            .catch(e => {{
                console.warn(e)
            }})
    }}
'''
    text, did = replace_once(text, old_direct, new_direct, "direct archive ranges")
    changed = changed or did

    old_mount = '''    onMounted(() => {
        if (camera.serverType)
            getRbtRanges()
        else
            getDmRanges()
    });
'''
    new_mount = '''    onMounted(() => {
        if (managedCamera)
            getDirectRanges()
        else if (camera.serverType)
            getRbtRanges()
        else
            getDirectRanges()
    });
'''
    text, did = replace_once(text, old_mount, new_mount, "archive range routing")
    changed = changed or did

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_controls(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    old = '''const downloadHandler = () => {
  const from = dayjs(range.date).add(downloadStart.value, "second").format("YYYY-MM-DD HH:mm:ss");
  const to = dayjs(range.date).add(downloadEnd.value, "second").format("YYYY-MM-DD HH:mm:ss");

  api.get('/cctv/recPrepare', {id: camera.id, from, to})
      .then(res => api.get('/cctv/recDownload', {id: res}))
      .then(res => {
        console.log(res)
        const uuid = crypto.randomUUID()
        const notification = {
          title: t('global.video_in_progress'),
          body: t('global.video_in_progress_description'),
        }
        push.addNotification({
          notification,
          from: 'system',
          collapseKey: '',
          messageId: uuid,
        })
        setTimeout(() => {
          push.removeNotification(uuid)
        }, 5000)
      })
}
'''
    new = f'''// {MARKER}: permanent NewDomofon camera links can export MP4 directly.
const managedCamera = /^m(?:1|ct1)\\./.test(String(camera.token || ""));

const addDownloadNotification = () => {{
  const uuid = crypto.randomUUID()
  const notification = {{
    title: t('global.video_in_progress'),
    body: t('global.video_in_progress_description'),
  }}
  push.addNotification({{
    notification,
    from: 'system',
    collapseKey: '',
    messageId: uuid,
  }})
  setTimeout(() => {{
    push.removeNotification(uuid)
  }}, 5000)
}}

const downloadHandler = () => {{
  const fromMoment = dayjs(range.date).add(downloadStart.value, "second");
  const toMoment = dayjs(range.date).add(downloadEnd.value, "second");
  const from = fromMoment.format("YYYY-MM-DD HH:mm:ss");
  const to = toMoment.format("YYYY-MM-DD HH:mm:ss");

  if (managedCamera) {{
    const duration = Math.max(1, toMoment.diff(fromMoment, "second"));
    const baseUrl = camera.url.replace(/\\/+$/, "");
    const href = `${{baseUrl}}/archive-${{fromMoment.unix()}}-${{duration}}.mp4?token=${{encodeURIComponent(camera.token)}}`;
    const link = document.createElement('a');
    link.href = href;
    link.download = `camera-${{camera.id}}-${{fromMoment.format('YYYYMMDD-HHmmss')}}.mp4`;
    link.rel = 'noopener';
    document.body.appendChild(link);
    link.click();
    link.remove();
    addDownloadNotification();
    return;
  }}

  api.get('/cctv/recPrepare', {{id: camera.id, from, to}})
      .then(res => api.get('/cctv/recDownload', {{id: res}}))
      .then(() => addDownloadNotification())
}}
'''
    text, changed = replace_once(text, old, new, "direct managed-camera download")
    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/SmartYard-Vue")
    args = parser.parse_args()

    root = Path(args.project_dir).resolve()
    targets = {
        "src/lib/player.ts": patch_player,
        "src/components/VideoCard.vue": patch_video_card,
        "src/components/VideoModal.vue": patch_video_modal,
        "src/hooks/useRanges.ts": patch_ranges,
        "src/components/CustomControls.vue": patch_controls,
    }

    for relative in targets:
        if not (root / relative).is_file():
            raise SystemExit(f"SmartYard-Vue source not found: {root / relative}")

    originals = {relative: (root / relative).read_bytes() for relative in targets}
    changed: list[str] = []
    for relative, patcher in targets.items():
        if patcher(root / relative):
            changed.append(relative)

    if changed:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        backup = root / ".newdomofon-backups" / f"media-compat-{stamp}"
        for relative in changed:
            destination = backup / f"{relative}.before"
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(originals[relative])
        print(f"backup={backup}")

    print("SmartYard-Vue NewDomofon media compatibility prepared")
    if changed:
        for relative in changed:
            print(f"  changed: {relative}")
    else:
        print("  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
