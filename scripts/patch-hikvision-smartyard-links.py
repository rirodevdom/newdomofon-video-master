#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "newdomofon-hikvision-smartyard-links-v1"


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1), True


def patch_internal_resolver(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return False

    type_anchor = """type ManagedCameraNodeRow = CameraNodeRow & {
  managed_token_id: string;
  managed_token_name: string;
  managed_token_generation: number;
  managed_token_scopes: string[];
  managed_token_active: boolean;
  managed_token_expires_at: string | null;
  managed_token_created_by: string | null;
};
"""
    type_block = type_anchor + """

type HikvisionSmartYardRow = {
  channel_external_id: string;
  device_id: string;
  physical_channel: number;
  channel_name: string;
  channel_enabled: boolean;
  channel_online: boolean | null;
  archive_storage: 'node' | 'device';
  device_enabled: boolean;
  node_id: string;
  node_name: string;
  node_enabled: boolean;
  node_internal_url: string | null;
  node_base_url: string | null;
  node_public_url: string | null;
  node_media_secret: string;
};
"""
    text, _ = replace_once(text, type_anchor, type_block, "Hikvision SmartYard resolver type")

    use_anchor = "internalSmartYardRouter.use(requireInternal);"
    helpers = r'''function hikvisionSmartYardStreamName(deviceId: string, physicalChannel: number): string {
  const device = String(deviceId || '').replace(/[^A-Za-z0-9]/g, '').toLowerCase();
  return `hik_${device}_${Math.max(1, Math.trunc(Number(physicalChannel) || 1))}`;
}

function hikvisionNodeUrl(channel: HikvisionSmartYardRow): string {
  // Hikvision-node deployments can retain an old generic internal URL after a
  // migration. Prefer the explicitly published Hikvision URL, then the base
  // URL, and only then the internal address.
  return String(channel.node_public_url || channel.node_base_url || channel.node_internal_url || '').replace(/\/+$/, '');
}

function sendHikvisionResolved(
  res: any,
  channel: HikvisionSmartYardRow,
  upstreamScope: 'camera' | 'events',
  userId: string
) {
  const resolvedNodeUrl = hikvisionNodeUrl(channel);
  if (!resolvedNodeUrl) return res.status(409).json({ error: 'Assigned Hikvision node URL is not configured' });

  const ttlSeconds = upstreamTtlSeconds();
  const now = Math.floor(Date.now() / 1000);
  const scopes = upstreamScope === 'events'
    ? ['events']
    : ['live', 'archive', 'snapshot'];
  const upstreamToken = signUpstreamToken(channel.node_media_secret, {
    channel_id: channel.channel_external_id,
    scopes,
    iat: now,
    exp: now + ttlSeconds
  });
  const streamName = hikvisionSmartYardStreamName(channel.device_id, channel.physical_channel);

  res.setHeader('cache-control', 'no-store');
  return res.json({
    ok: true,
    camera: {
      id: channel.channel_external_id,
      name: channel.channel_name,
      stream_name: streamName
    },
    node: {
      id: channel.node_id,
      name: channel.node_name,
      url: resolvedNodeUrl,
      kind: 'hikvision'
    },
    target: {
      kind: 'hikvision',
      channel_id: channel.channel_external_id,
      device_id: channel.device_id,
      physical_channel: channel.physical_channel,
      archive_storage: channel.archive_storage
    },
    upstream_token: upstreamToken,
    upstream_scope: upstreamScope,
    expires_in: ttlSeconds,
    token_source: 'hikvision-node',
    user_id: userId
  });
}

'''
    text, _ = replace_once(text, use_anchor, helpers + use_anchor, "Hikvision SmartYard resolver helpers")

    resolve_anchor = """internalSmartYardRouter.post('/resolve', asyncHandler(async (req, res) => {
  const body = resolveSchema.parse(req.body || {});

"""
    resolve_block = resolve_anchor + r'''  // newdomofon-hikvision-smartyard-links-v1
  // Hikvision channels intentionally remain outside the generic `cameras`
  // table. A permanent external SmartYard token identifies the native channel;
  // the resolver validates it against the assigned Hikvision-node and then
  // mints a short-lived native media token with the exact scopes required by
  // the compatibility gateway.
  const hikvisionToken = parseToken(body.token);
  if (hikvisionToken && String(hikvisionToken.payload.target || '') === 'hikvision') {
    const channelId = String(hikvisionToken.payload.channel_id || '').trim();
    const tokenStream = String(hikvisionToken.payload.stream_name || '').trim();
    const tokenScope = String(hikvisionToken.payload.scope || '').trim();
    if (!channelId || !streamNameSchema.safeParse(tokenStream).success || !['camera', 'live', 'archive'].includes(tokenScope)) {
      return res.status(401).json({ error: 'Invalid Hikvision SmartYard token payload' });
    }

    const result = await query<HikvisionSmartYardRow>(
      `SELECT h.channel_external_id,
              h.device_id::text AS device_id,
              h.physical_channel,
              h.name AS channel_name,
              h.enabled AS channel_enabled,
              h.online AS channel_online,
              h.archive_storage,
              d.is_enabled AS device_enabled,
              ds.id::text AS node_id,
              ds.name AS node_name,
              ds.is_enabled AS node_enabled,
              ds.internal_url AS node_internal_url,
              ds.base_url AS node_base_url,
              ds.public_base_url AS node_public_url,
              ds.media_secret AS node_media_secret
         FROM hikvision_node_channels h
         JOIN devices d ON d.id = h.device_id
         JOIN dvr_servers ds ON ds.id = h.dvr_server_id
        WHERE h.channel_external_id = $1
        LIMIT 1`,
      [channelId]
    );
    const channel = result.rows[0];
    if (!channel || !channel.channel_enabled || !channel.device_enabled || !channel.node_enabled || !channel.node_media_secret) {
      return res.status(404).json({ error: 'Hikvision channel or assigned node is unavailable' });
    }

    const expectedStream = hikvisionSmartYardStreamName(channel.device_id, channel.physical_channel);
    if (tokenStream !== expectedStream || (body.stream_name && body.stream_name !== expectedStream)) {
      return res.status(403).json({ error: 'Hikvision SmartYard token stream mismatch' });
    }

    const exp = Number(hikvisionToken.payload.exp);
    if (Number.isFinite(exp) && exp < Math.floor(Date.now() / 1000)) {
      return res.status(401).json({ error: 'Hikvision SmartYard token expired' });
    }
    if (!verifySignature(hikvisionToken.body, hikvisionToken.signature, channel.node_media_secret)) {
      return res.status(401).json({ error: 'Invalid Hikvision SmartYard token signature' });
    }

    return sendHikvisionResolved(
      res,
      channel,
      body.upstream_scope,
      String(hikvisionToken.payload.user_id || 'smartyard-hikvision')
    );
  }

'''
    text, _ = replace_once(text, resolve_anchor, resolve_block, "Hikvision SmartYard resolver branch")

    if MARKER not in text or "sendHikvisionResolved" not in text or "channel_id: channel.channel_external_id" not in text:
        raise RuntimeError("Hikvision SmartYard resolver markers are incomplete")
    path.write_text(text, encoding="utf-8")
    return True


def patch_links(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return False

    token_anchor = """function cameraToken(secret: string, payload: Record<string, unknown>) {
  const encoded = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto.createHmac('sha256', secret).update(encoded).digest('base64url');
  return `${encoded}.${signature}`;
}
"""
    token_block = token_anchor + r'''

function hikvisionSmartYardStreamName(deviceId: string, physicalChannel: number): string {
  const device = String(deviceId || '').replace(/[^A-Za-z0-9]/g, '').toLowerCase();
  return `hik_${device}_${Math.max(1, Math.trunc(Number(physicalChannel) || 1))}`;
}
'''
    text, _ = replace_once(text, token_anchor, token_block, "Hikvision SmartYard link helper")

    route_anchor = "smartYardLinksRouter.post('/:cameraId', asyncHandler(async (req, res) => {"
    route = r'''// newdomofon-hikvision-smartyard-links-v1
smartYardLinksRouter.post('/hikvision/:channelId', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!authReq.user) return res.status(401).json({ error: 'Unauthorized' });

  const result = await query<{
    channel_external_id: string;
    device_id: string;
    physical_channel: number;
    channel_name: string;
    channel_enabled: boolean;
    channel_online: boolean | null;
    archive_storage: 'node' | 'device';
    device_name: string;
    device_enabled: boolean;
    node_name: string;
    node_media_secret: string;
    node_enabled: boolean;
  }>(
    `SELECT h.channel_external_id,
            h.device_id::text AS device_id,
            h.physical_channel,
            h.name AS channel_name,
            h.enabled AS channel_enabled,
            h.online AS channel_online,
            h.archive_storage,
            d.name AS device_name,
            d.is_enabled AS device_enabled,
            ds.name AS node_name,
            ds.media_secret AS node_media_secret,
            ds.is_enabled AS node_enabled
       FROM hikvision_node_channels h
       JOIN devices d ON d.id = h.device_id
       JOIN dvr_servers ds ON ds.id = h.dvr_server_id
      WHERE h.channel_external_id = $1
      LIMIT 1`,
    [decodeURIComponent(String(req.params.channelId || ''))]
  );
  const channel = result.rows[0];
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  if (!channel.channel_enabled || !channel.device_enabled || !channel.node_enabled || !channel.node_media_secret) {
    return res.status(409).json({ error: 'Hikvision channel or assigned node is unavailable' });
  }

  const origin = publicOrigin(authReq);
  if (!origin) return res.status(500).json({ error: 'Public SmartYard base URL cannot be determined' });

  const streamName = hikvisionSmartYardStreamName(channel.device_id, channel.physical_channel);
  const token = cameraToken(channel.node_media_secret, {
    target: 'hikvision',
    channel_id: channel.channel_external_id,
    stream_name: streamName,
    user_id: authReq.user.id,
    scope: 'camera',
    link_version: String(process.env.PERMANENT_MEDIA_LINK_VERSION || '1')
  });
  const url = `${origin}/${encodeURIComponent(streamName)}/?token=${encodeURIComponent(token)}`;

  res.json({
    camera: {
      id: channel.channel_external_id,
      name: channel.channel_name,
      stream_name: streamName,
      device_id: channel.device_id,
      device_name: channel.device_name,
      physical_channel: channel.physical_channel,
      archive_storage: channel.archive_storage,
      online: channel.channel_online
    },
    node_name: channel.node_name,
    smartyard_url: url,
    common_url: url,
    camera_url: url,
    camera_token: token,
    permanent: true,
    expires_at: null,
    mode: 'master-smartyard-compat-hikvision'
  });
}));

'''
    text, _ = replace_once(text, route_anchor, route + route_anchor, "Hikvision SmartYard link route")

    if MARKER not in text or "master-smartyard-compat-hikvision" not in text:
        raise RuntimeError("Hikvision SmartYard link route markers are incomplete")
    path.write_text(text, encoding="utf-8")
    return True


def patch_frontend(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return False

    old_actions = """            <td class=\"text-right\">
              <v-btn
                size=\"small\"
                color=\"primary\"
                variant=\"tonal\"
                prepend-icon=\"mdi-play-circle\"
                :disabled=\"channel.online === false || !channel.enabled\"
                :to=\"`/hikvision/${encodeURIComponent(channel.id)}`\"
              >
                Просмотр
              </v-btn>
            </td>"""
    new_actions = """            <td class=\"text-right\">
              <!-- newdomofon-hikvision-smartyard-links-v1 -->
              <div class=\"d-flex ga-2 justify-end\">
                <v-btn
                  size=\"small\"
                  variant=\"tonal\"
                  prepend-icon=\"mdi-link-variant\"
                  :loading=\"smartYardLoading === channel.id\"
                  :disabled=\"channel.online === false || !channel.enabled\"
                  @click=\"openSmartYardLink(channel)\"
                >
                  SmartYard
                </v-btn>
                <v-btn
                  size=\"small\"
                  color=\"primary\"
                  variant=\"tonal\"
                  prepend-icon=\"mdi-play-circle\"
                  :disabled=\"channel.online === false || !channel.enabled\"
                  :to=\"`/hikvision/${encodeURIComponent(channel.id)}`\"
                >
                  Просмотр
                </v-btn>
              </div>
            </td>"""
    text, _ = replace_once(text, old_actions, new_actions, "Hikvision SmartYard action button")

    card_end = """    </v-card>
  </v-container>
</template>"""
    dialogs = """    </v-card>

    <v-dialog v-model=\"smartYardDialog\" max-width=\"760\">
      <v-card>
        <v-card-title>Подключение Hikvision-канала к SmartYard</v-card-title>
        <v-card-text>
          <div class=\"text-medium-emphasis mb-3\">
            Используйте эту ссылку как URL камеры в smartyard-server. Live, архив, превью и события будут доступны через тот же SmartYard-compatible интерфейс, что и у обычных камер.
          </div>
          <v-text-field
            v-model=\"smartYardLink\"
            label=\"SmartYard URL\"
            readonly
            hide-details
            @click=\"copySmartYardLink\"
          />
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn @click=\"smartYardDialog = false\">Закрыть</v-btn>
          <v-btn color=\"primary\" prepend-icon=\"mdi-content-copy\" @click=\"copySmartYardLink\">Копировать</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <v-snackbar v-model=\"noticeVisible\" timeout=\"2500\">{{ notice }}</v-snackbar>
  </v-container>
</template>"""
    text, _ = replace_once(text, card_end, dialogs, "Hikvision SmartYard link dialog")

    state_anchor = """const loading = ref(false);
const error = ref('');"""
    state_block = """const loading = ref(false);
const error = ref('');
const smartYardLoading = ref('');
const smartYardDialog = ref(false);
const smartYardLink = ref('');
const notice = ref('');
const noticeVisible = ref(false);"""
    text, _ = replace_once(text, state_anchor, state_block, "Hikvision SmartYard frontend state")

    mounted_anchor = "onMounted(() => { void load(); });"
    methods = r'''async function openSmartYardLink(channel: any) {
  smartYardLoading.value = String(channel.id || '');
  error.value = '';
  try {
    const response = await api.post(`/tokens/smartyard-links/hikvision/${encodeURIComponent(channel.id)}`);
    smartYardLink.value = String(response.data?.smartyard_url || response.data?.camera_url || '');
    if (!smartYardLink.value) throw new Error('Master не вернул SmartYard URL');
    smartYardDialog.value = true;
  } catch (err: any) {
    error.value = err.response?.data?.error || err.message || 'Не удалось создать SmartYard-ссылку';
  } finally {
    smartYardLoading.value = '';
  }
}

async function copySmartYardLink() {
  if (!smartYardLink.value) return;
  try {
    await navigator.clipboard.writeText(smartYardLink.value);
    notice.value = 'SmartYard URL скопирован';
  } catch {
    notice.value = 'Не удалось скопировать автоматически';
  }
  noticeVisible.value = true;
}

'''
    text, _ = replace_once(text, mounted_anchor, methods + mounted_anchor, "Hikvision SmartYard frontend methods")

    if MARKER not in text or "openSmartYardLink" not in text or "smartyard-links/hikvision" not in text:
        raise RuntimeError("Hikvision SmartYard frontend markers are incomplete")
    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    parser.add_argument("--backend-only", action="store_true")
    parser.add_argument("--frontend-only", action="store_true")
    args = parser.parse_args()

    if args.backend_only and args.frontend_only:
        raise SystemExit("Choose only one of --backend-only or --frontend-only")

    project = Path(args.project_dir).resolve()
    targets: list[tuple[Path, object]] = []
    if not args.frontend_only:
        targets.extend([
            (project / "backend/src/routes/internalSmartYard.ts", patch_internal_resolver),
            (project / "backend/src/routes/smartyardLinks.ts", patch_links),
        ])
    if not args.backend_only:
        targets.append((project / "frontend/src/views/HikvisionChannelsView.vue", patch_frontend))

    changed: list[str] = []
    for path, patcher in targets:
        if not path.is_file():
            raise SystemExit(f"Target not found: {path}")
        if patcher(path):
            changed.append(str(path.relative_to(project)))

    print("Hikvision SmartYard links prepared")
    if changed:
        for item in changed:
            print(f"  changed: {item}")
    else:
        print("  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
