#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "v308-hikvision-unified-camera-catalog"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1)


def patch_backend_cameras(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return

    old = '''camerasRouter.get('/', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const baseQuery = `SELECT ${cameraSelect}, cg.name AS group_name, node.name AS dvr_server_name,
                            device.name AS device_name, device.connection_type AS device_connection_type,
                            'node'::text AS device_archive_storage,
                            EXISTS(SELECT 1 FROM user_favorites f WHERE f.camera_id = c.id AND f.user_id = $1) AS favorite
                       FROM cameras c
                       JOIN devices device ON device.id = c.device_id
                       LEFT JOIN camera_groups cg ON cg.id = c.group_id
                       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id`;

  if (isAdmin(authReq)) {
    const result = await query(`${baseQuery} ORDER BY c.name ASC`, [authReq.user!.id]);
    return res.json({ items: result.rows });
  }

  const result = await query(`${baseQuery} WHERE c.is_enabled = true ORDER BY c.name ASC`, [authReq.user!.id]);
  res.json({ items: result.rows });
}));'''

    new = f'''// {MARKER}
camerasRouter.get('/', asyncHandler(async (req, res) => {{
  const authReq = req as AuthRequest;
  const admin = isAdmin(authReq);
  const baseQuery = `SELECT ${{cameraSelect}}, cg.name AS group_name, node.name AS dvr_server_name,
                            device.name AS device_name, device.connection_type AS device_connection_type,
                            'node'::text AS device_archive_storage,
                            EXISTS(SELECT 1 FROM user_favorites f WHERE f.camera_id = c.id AND f.user_id = $1) AS favorite,
                            'camera'::text AS camera_kind, false AS is_hikvision, NULL::boolean AS online,
                            NULL::integer AS physical_channel, NULL::text AS primary_stream_id
                       FROM cameras c
                       JOIN devices device ON device.id = c.device_id
                       LEFT JOIN camera_groups cg ON cg.id = c.group_id
                       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id`;

  const normal = await query(
    admin ? `${{baseQuery}} ORDER BY c.name ASC` : `${{baseQuery}} WHERE c.is_enabled = true ORDER BY c.name ASC`,
    [authReq.user!.id]
  );

  const hikvision = await query(
    `SELECT h.channel_external_id AS id,
            NULL::uuid AS group_id,
            h.dvr_server_id,
            h.device_id,
            h.name,
            ('hik_' || replace(h.device_id::text, '-', '') || '_' || h.physical_channel::text) AS stream_name,
            ''::text AS source_url,
            h.archive_storage,
            NULL::text AS rtmp_push_url,
            NULL::double precision AS latitude,
            NULL::double precision AS longitude,
            NULL::integer AS direction_deg,
            NULL::integer AS fov_deg,
            h.retention_days,
            (h.enabled AND device.is_enabled) AS is_enabled,
            h.updated_at AS created_at,
            h.updated_at,
            NULL::text AS onvif_xaddr,
            NULL::integer AS onvif_port,
            NULL::text AS onvif_username,
            NULL::text AS onvif_profile_token,
            NULL::jsonb AS onvif_device_info,
            NULL::timestamptz AS onvif_last_sync_at,
            false AS is_onvif,
            NULL::text AS group_name,
            node.name AS dvr_server_name,
            device.name AS device_name,
            'HIKVISION'::text AS device_connection_type,
            h.archive_storage AS device_archive_storage,
            false AS favorite,
            'hikvision'::text AS camera_kind,
            true AS is_hikvision,
            h.online,
            h.physical_channel,
            h.primary_stream_id
       FROM hikvision_node_channels h
       JOIN devices device ON device.id = h.device_id
       LEFT JOIN dvr_servers node ON node.id = h.dvr_server_id
      WHERE $1::boolean OR (h.enabled = true AND device.is_enabled = true)
      ORDER BY h.name ASC`,
    [admin]
  );

  const items = [...normal.rows, ...hikvision.rows].sort((left: any, right: any) =>
    String(left.name || '').localeCompare(String(right.name || ''), 'ru')
  );
  res.json({{ items }});
}}));'''

    text = replace_once(text, old, new, "unified cameras GET")
    path.write_text(text, encoding="utf-8")


def patch_backend_links(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "hikvision_format_links_v308" in text:
        return
    if "smartYardLinksRouter.post('/hikvision/:channelId'" not in text:
        raise RuntimeError("Hikvision SmartYard route must be materialized before unified links patch")

    old = '''  const url = `${origin}/${encodeURIComponent(streamName)}/?token=${encodeURIComponent(token)}`;
  res.json({
    item: {
      channel_id: channel.id,
      name: channel.name,
      stream_name: streamName,
      device_name: channel.device_name,
      dvr_server_name: channel.dvr_server_name,
      url,
      permanent: true,
      expires_at: null
    }
  });'''

    new = '''  const encodedToken = encodeURIComponent(token);
  const base = `${origin}/${encodeURIComponent(streamName)}`;
  const url = `${base}/?token=${encodedToken}`;
  const formatLinks = [
    { type: 'HLS', label: 'HLS', available: true, url: `${base}/index.m3u8?token=${encodedToken}` },
    { type: 'MPEG-TS', label: 'MPEG-TS', available: false, url: null, note: 'Hikvision SmartYard gateway currently exposes this source as HLS; live.ts is not enabled.' },
    { type: 'DASH', label: 'DASH', available: false, url: null, note: 'Hikvision SmartYard gateway currently exposes this source as HLS; DASH is not enabled.' },
    { type: 'RTSP', label: 'RTSP', available: false, url: null, note: 'The permanent Hikvision SmartYard token is HTTP-gateway scoped; RTSP relay is not enabled for it.' },
    { type: 'JPEG', label: 'JPEG', available: true, url: `${base}/snapshot.jpg?token=${encodedToken}` }
  ];
  // hikvision_format_links_v308
  res.json({
    item: {
      channel_id: channel.id,
      name: channel.name,
      stream_name: streamName,
      device_name: channel.device_name,
      dvr_server_name: channel.dvr_server_name,
      url,
      permanent: true,
      expires_at: null
    },
    camera: { id: channel.id, name: channel.name, stream_name: streamName, kind: 'hikvision' },
    node_name: channel.dvr_server_name,
    camera_token: token,
    live_token: token,
    archive_token: token,
    smartyard_url: url,
    common_url: url,
    camera_url: url,
    player_url: url,
    primary_url: url,
    live_url: `${base}/index.m3u8?token=${encodedToken}`,
    mpeg_ts_url: null,
    dash_url: null,
    rtsp_url: null,
    jpeg_url: `${base}/snapshot.jpg?token=${encodedToken}`,
    format_links: formatLinks,
    archive_url_template: `${base}/archive.m3u8?start=<ISO_START>&end=<ISO_END>&token=${encodedToken}`,
    events_url_template: `${base}/events.json?start=<ISO_START>&end=<ISO_END>&token=${encodedToken}`,
    archive_source: channel.archive_storage,
    permanent: true,
    expires_at: null,
    mode: 'master-smartyard-compat-hikvision'
  });'''

    text = replace_once(text, old, new, "Hikvision full format links")
    path.write_text(text, encoding="utf-8")


def patch_frontend(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "hikvisionLinksDialog" in text:
        return

    text = replace_once(
        text,
        '''              <div v-if="canManageTokens" class="d-flex flex-wrap ga-1">''',
        '''              <div v-if="camera.is_hikvision" class="d-flex flex-wrap ga-1">
                <v-chip size="x-small" variant="tonal" color="deep-purple">Hikvision · постоянная ссылка</v-chip>
              </div>
              <div v-else-if="canManageTokens" class="d-flex flex-wrap ga-1">''',
        "Hikvision token column",
    )

    text = replace_once(
        text,
        '''              <v-btn size="small" color="primary" variant="tonal" :to="`/cameras/${camera.id}`">Просмотр</v-btn>
              <v-btn
                v-if="canManageTokens"
                size="small"
                variant="tonal"
                class="ml-2"
                prepend-icon="mdi-key-chain"
                @click="openTokenDialog(camera)"
              >
                Токены
              </v-btn>
              <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openEdit(camera)">
                Включение
              </v-btn>''',
        '''              <v-btn size="small" color="primary" variant="tonal" :to="cameraViewRoute(camera)">Просмотр</v-btn>
              <v-btn
                v-if="canManageTokens && !camera.is_hikvision"
                size="small"
                variant="tonal"
                class="ml-2"
                prepend-icon="mdi-key-chain"
                @click="openTokenDialog(camera)"
              >
                Токены
              </v-btn>
              <v-btn
                v-if="canManageTokens && camera.is_hikvision"
                size="small"
                variant="tonal"
                class="ml-2"
                prepend-icon="mdi-link-variant"
                :loading="loadingHikvisionLinks && hikvisionLinksCamera?.id === camera.id"
                @click="openHikvisionLinks(camera)"
              >
                Ссылки
              </v-btn>
              <v-btn v-if="auth.isAdmin && !camera.is_hikvision" size="small" variant="tonal" class="ml-2" @click="openEdit(camera)">
                Включение
              </v-btn>''',
        "camera action buttons",
    )

    text = replace_once(
        text,
        '''    </v-dialog>
  </v-container>''',
        '''    </v-dialog>

    <v-dialog v-model="hikvisionLinksDialog" max-width="980">
      <v-card>
        <v-card-title>Ссылки Hikvision: {{ hikvisionLinksCamera?.name }}</v-card-title>
        <v-card-subtitle class="pb-3"><code>{{ hikvisionLinksCamera?.stream_name }}</code></v-card-subtitle>
        <v-card-text>
          <v-alert type="info" variant="tonal" density="compact" class="mb-4">
            Ссылка постоянная. HLS, JPEG, архив и события обслуживаются Hikvision SmartYard gateway. Форматы, которые gateway пока не поддерживает, показаны как недоступные вместо выдачи нерабочего URL.
          </v-alert>
          <v-text-field
            v-if="hikvisionLinksData?.common_url"
            :model-value="hikvisionLinksData.common_url"
            label="Общая ссылка плеера"
            readonly
            append-inner-icon="mdi-content-copy"
            @click:append-inner="copyLink(hikvisionLinksData.common_url)"
          />
          <v-table density="compact">
            <thead><tr><th>Формат</th><th>Статус</th><th>Ссылка / пояснение</th></tr></thead>
            <tbody>
              <tr v-for="item in hikvisionLinksData?.format_links || []" :key="item.type">
                <td>{{ item.label || item.type }}</td>
                <td><v-chip size="x-small" :color="item.available ? 'success' : 'warning'">{{ item.available ? 'доступно' : 'недоступно' }}</v-chip></td>
                <td>
                  <div v-if="item.url" class="d-flex align-center ga-2">
                    <code class="text-wrap">{{ item.url }}</code>
                    <v-btn size="x-small" icon="mdi-content-copy" variant="text" @click="copyLink(item.url)" />
                  </div>
                  <span v-else class="text-medium-emphasis">{{ item.note || 'Формат не поддерживается' }}</span>
                </td>
              </tr>
            </tbody>
          </v-table>
          <v-text-field
            v-if="hikvisionLinksData?.archive_url_template"
            class="mt-4"
            :model-value="hikvisionLinksData.archive_url_template"
            label="Шаблон архива"
            readonly
            append-inner-icon="mdi-content-copy"
            @click:append-inner="copyLink(hikvisionLinksData.archive_url_template)"
          />
          <v-text-field
            v-if="hikvisionLinksData?.events_url_template"
            :model-value="hikvisionLinksData.events_url_template"
            label="Шаблон событий"
            readonly
            append-inner-icon="mdi-content-copy"
            @click:append-inner="copyLink(hikvisionLinksData.events_url_template)"
          />
        </v-card-text>
        <v-card-actions><v-spacer /><v-btn variant="tonal" @click="hikvisionLinksDialog = false">Закрыть</v-btn></v-card-actions>
      </v-card>
    </v-dialog>
  </v-container>''',
        "Hikvision links dialog",
    )

    text = replace_once(
        text,
        '''const tokenDialog = ref(false);
const saving = ref(false);''',
        '''const tokenDialog = ref(false);
const hikvisionLinksDialog = ref(false);
const hikvisionLinksCamera = ref<any | null>(null);
const hikvisionLinksData = ref<any | null>(null);
const loadingHikvisionLinks = ref(false);
const saving = ref(false);''',
        "Hikvision links state",
    )

    text = replace_once(
        text,
        '''function cameraProtocolTitle(camera: any) {
  return camera.is_onvif ? 'ONVIF' : 'RTSP';
}

function cameraProtocolColor(camera: any) {
  return camera.is_onvif ? 'indigo' : 'blue';
}''',
        '''function cameraProtocolTitle(camera: any) {
  if (camera.is_hikvision) return 'HIKVISION';
  return camera.is_onvif ? 'ONVIF' : 'RTSP';
}

function cameraProtocolColor(camera: any) {
  if (camera.is_hikvision) return 'deep-purple';
  return camera.is_onvif ? 'indigo' : 'blue';
}

function cameraViewRoute(camera: any) {
  return camera.is_hikvision ? `/hikvision/${encodeURIComponent(camera.id)}` : `/cameras/${camera.id}`;
}''',
        "Hikvision protocol and route",
    )

    text = replace_once(
        text,
        '''function openTokenDialog(camera: any) {
  tokenCamera.value = camera;''',
        '''async function openHikvisionLinks(camera: any) {
  hikvisionLinksCamera.value = camera;
  hikvisionLinksData.value = null;
  loadingHikvisionLinks.value = true;
  try {
    const { data } = await api.post(`/smartyard-links/hikvision/${encodeURIComponent(camera.id)}`);
    hikvisionLinksData.value = data;
    hikvisionLinksDialog.value = true;
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось сформировать ссылки Hikvision', 'error');
  } finally {
    loadingHikvisionLinks.value = false;
  }
}

async function copyLink(value: string) {
  try {
    await navigator.clipboard.writeText(String(value || ''));
    notify('Ссылка скопирована');
  } catch {
    notify('Не удалось скопировать ссылку', 'error');
  }
}

function openTokenDialog(camera: any) {
  tokenCamera.value = camera;''',
        "Hikvision links actions",
    )

    required = [
        "cameraViewRoute(camera)",
        "camera.is_hikvision",
        "openHikvisionLinks(camera)",
        "hikvisionLinksDialog",
        "HIKVISION",
    ]
    missing = [marker for marker in required if marker not in text]
    if missing:
        raise RuntimeError(f"Hikvision unified camera UI markers missing: {missing}")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    parser.add_argument("--backend-only", action="store_true")
    parser.add_argument("--frontend-only", action="store_true")
    args = parser.parse_args()
    if args.backend_only and args.frontend_only:
        raise SystemExit("choose at most one of --backend-only/--frontend-only")

    root = Path(args.project_dir).resolve()
    if not args.frontend_only:
        patch_backend_cameras(root / "backend/src/routes/cameras.ts")
        patch_backend_links(root / "backend/src/routes/smartyardLinks.ts")
        print("Hikvision channels are projected into the unified cameras API without duplicating cameras table rows")
        print("Hikvision permanent links now expose the same format-link response shape as ordinary cameras")

    if not args.backend_only:
        patch_frontend(root / "frontend/src/views/CamerasView.vue")
        print("Unified Cameras UI now shows Hikvision channels with their player route and full links dialog")


if __name__ == "__main__":
    main()
