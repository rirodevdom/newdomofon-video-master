import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { resolveOnvifStreamUri } from '../services/onvif.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const onvifRouter = Router();
onvifRouter.use(requireAuth, requireRole('super_admin', 'operator'));

const connectSchema = z.object({
  ip: z.string().min(1),
  port: z.coerce.number().int().min(1).max(65535).default(80),
  username: z.string().optional(),
  password: z.string().optional()
});

const streamUriSchema = z.object({
  camera_id: z.string().uuid().optional(),
  cameraId: z.string().uuid().optional(),
  id: z.string().uuid().optional(),
  device_id: z.string().uuid().optional(),
  deviceId: z.string().uuid().optional(),
  ip: z.string().optional(),
  host: z.string().optional(),
  xaddr: z.string().optional(),
  port: z.coerce.number().int().min(1).max(65535).optional(),
  username: z.string().optional(),
  password: z.string().optional(),
  dvr_server_id: z.string().uuid().optional(),
  dvrServerId: z.string().uuid().optional()
});

type ConnectBody = z.infer<typeof connectSchema>;
type StoredConnectBody = {
  body: ConnectBody;
  dvrServerId: string | null;
};

function dvrBaseUrl() {
  return process.env.DVR_ENGINE_URL || process.env.DVR_URL || 'http://127.0.0.1:3010';
}

async function dvrServerBaseUrl(dvrServerId: string | null | undefined) {
  if (!dvrServerId) return null;

  const result = await query(
    `SELECT internal_url, public_base_url, base_url
       FROM public.dvr_servers
      WHERE id = $1`,
    [dvrServerId]
  );
  const server = result.rows[0] as any;
  return server?.internal_url || server?.public_base_url || server?.base_url || null;
}

function cleanHostFromXaddr(input: string | null | undefined) {
  return String(input || '')
    .trim()
    .replace(/^https?:\/\//i, '')
    .replace(/\/onvif\/device_service.*$/i, '')
    .replace(/:\d+$/i, '')
    .replace(/\/+$/g, '');
}

function parseRtspCredentials(sourceUrl: string | null | undefined) {
  if (!sourceUrl) return { username: '', password: '' };

  try {
    const url = new URL(sourceUrl);
    if (url.protocol !== 'rtsp:') return { username: '', password: '' };

    return {
      username: url.username ? decodeURIComponent(url.username) : '',
      password: url.password ? decodeURIComponent(url.password) : ''
    };
  } catch {
    return { username: '', password: '' };
  }
}

async function cameraStoredConnectBody(cameraId: string): Promise<StoredConnectBody> {
  const result = await query(
    `SELECT c.id, device.dvr_server_id, c.source_url, c.onvif_xaddr, c.onvif_port,
            COALESCE(c.onvif_username, device.username) AS onvif_username,
            COALESCE(c.onvif_password, device.password) AS onvif_password,
            device.host AS device_host,
            device.port AS device_port
       FROM public.cameras c
       JOIN public.devices device ON device.id = c.device_id
      WHERE c.id = $1`,
    [cameraId]
  );

  if (!result.rowCount) throw new Error('Camera not found');

  const camera = result.rows[0] as any;
  const rtspCreds = parseRtspCredentials(camera.source_url);
  const ip = cleanHostFromXaddr(camera.onvif_xaddr) || String(camera.device_host || '').trim();

  if (!ip) throw new Error('Camera device has no ONVIF address saved');

  return {
    body: {
      ip,
      port: Number(camera.onvif_port || camera.device_port || 80),
      username: camera.onvif_username || rtspCreds.username || '',
      password: camera.onvif_password || rtspCreds.password || ''
    },
    dvrServerId: camera.dvr_server_id || null
  };
}

async function deviceStoredConnectBody(deviceId: string): Promise<StoredConnectBody> {
  const result = await query(
    `SELECT id, connection_type, dvr_server_id, host, port, username, password
       FROM public.devices
      WHERE id = $1`,
    [deviceId]
  );
  if (!result.rowCount) throw new Error('Device not found');

  const device = result.rows[0] as any;
  if (device.connection_type !== 'ONVIF') throw new Error('Device is not ONVIF');
  if (!device.host) throw new Error('Device has no ONVIF Host/IP configured');

  return {
    body: {
      ip: String(device.host),
      port: Number(device.port || 80),
      username: String(device.username || ''),
      password: String(device.password || '')
    },
    dvrServerId: device.dvr_server_id || null
  };
}

async function connectViaDvr(body: ConnectBody, baseUrl = dvrBaseUrl()) {
  const response = await fetch(`${baseUrl.replace(/\/+$/, '')}/onvif/connect`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });

  const text = await response.text();
  let payload: any;
  try { payload = text ? JSON.parse(text) : {}; } catch { payload = { error: text }; }

  if (!response.ok) throw new Error(payload?.error || `DVR ONVIF failed with HTTP ${response.status}`);
  return payload;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

async function resolveViaBackend(body: ConnectBody) {
  return resolveOnvifStreamUri({
    host: body.ip,
    port: body.port,
    username: body.username,
    password: body.password
  });
}

async function resolveStreamUri(body: ConnectBody, dvrServerId?: string | null) {
  const errors: string[] = [];
  const nodeUrl = await dvrServerBaseUrl(dvrServerId);

  if (nodeUrl) {
    try {
      return await connectViaDvr(body, nodeUrl);
    } catch (error) {
      errors.push(`node ${nodeUrl}: ${errorMessage(error)}`);
    }
  }

  try {
    return await resolveViaBackend(body);
  } catch (error) {
    errors.push(`backend: ${errorMessage(error)}`);
  }

  if (!nodeUrl) {
    try {
      return await connectViaDvr(body);
    } catch (error) {
      errors.push(`dvr ${dvrBaseUrl()}: ${errorMessage(error)}`);
    }
  }

  throw new Error(`ONVIF stream URI lookup failed: ${errors.join(' | ')}`);
}

onvifRouter.post('/connect', asyncHandler(async (req, res) => {
  const body = connectSchema.parse(req.body || {});
  res.json(await resolveStreamUri(body));
}));

onvifRouter.post('/stream-uri', asyncHandler(async (req, res) => {
  const raw = streamUriSchema.parse(req.body || {});
  const cameraId = raw.camera_id || raw.cameraId || raw.id;
  const deviceId = raw.device_id || raw.deviceId;

  if (deviceId) {
    try {
      const stored = await deviceStoredConnectBody(deviceId);
      const payload = await resolveStreamUri(stored.body, stored.dvrServerId);
      await query('UPDATE devices SET status = $2, last_check_at = now() WHERE id = $1', [deviceId, 'online']);
      return res.json(payload);
    } catch (error) {
      await query('UPDATE devices SET status = $2, last_check_at = now() WHERE id = $1', [deviceId, 'error']).catch(() => undefined);
      throw error;
    }
  }

  if (cameraId) {
    const stored = await cameraStoredConnectBody(cameraId);
    return res.json(await resolveStreamUri(stored.body, stored.dvrServerId));
  }

  const body = connectSchema.parse({
    ip: raw.ip || raw.host || cleanHostFromXaddr(raw.xaddr),
    port: raw.port || 80,
    username: raw.username,
    password: raw.password
  });

  res.json(await resolveStreamUri(body, raw.dvr_server_id || raw.dvrServerId || null));
}));
