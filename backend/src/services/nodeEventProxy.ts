import { query } from '../db.js';
import { signNodeMediaToken } from './nodeMediaToken.js';

export type CameraEventTarget = {
  id: string;
  stream_name: string;
  dvr_server_id: string | null;
  node_internal_url: string | null;
  node_public_base_url: string | null;
  node_media_secret: string | null;
  node_enabled: boolean | null;
  node_status: string | null;
};

export type NodeEventProxyResult = {
  ok: boolean;
  status: number;
  body: string;
  contentType: string;
};

function normalizeBase(raw: string | null | undefined): string | null {
  const value = String(raw || '').trim().replace(/\/+$/, '');
  if (!value) return null;
  return /^https?:\/\//i.test(value) ? value : `http://${value}`;
}

function uniqueBases(...values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of values) {
    const value = normalizeBase(raw);
    if (!value || seen.has(value)) continue;
    seen.add(value);
    out.push(value);
  }
  return out;
}

export async function getCameraEventTarget(cameraId: string): Promise<CameraEventTarget | null> {
  const result = await query<CameraEventTarget>(
    `SELECT c.id,
            c.stream_name,
            c.dvr_server_id,
            ds.internal_url AS node_internal_url,
            COALESCE(ds.public_base_url, ds.base_url) AS node_public_base_url,
            ds.media_secret AS node_media_secret,
            ds.is_enabled AS node_enabled,
            ds.status AS node_status
       FROM cameras c
       LEFT JOIN dvr_servers ds ON ds.id = c.dvr_server_id
      WHERE c.id = $1
      LIMIT 1`,
    [cameraId]
  );
  return result.rows[0] || null;
}

function serviceError(status: number, error: string, target: CameraEventTarget, retryable: boolean, detail?: string): NodeEventProxyResult {
  return {
    ok: false,
    status,
    contentType: 'application/json',
    body: JSON.stringify({
      error,
      camera_id: target.id,
      node_id: target.dvr_server_id,
      node_status: target.node_status,
      retryable,
      ...(detail ? { detail } : {})
    })
  };
}

async function fetchWithTimeout(url: string, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, {
      signal: controller.signal,
      headers: {
        accept: 'application/json',
        'x-forwarded-by': 'newdomofon-video-master'
      }
    });
  } finally {
    clearTimeout(timer);
  }
}

export async function fetchNodeEvents(params: {
  target: CameraEventTarget;
  userId: string;
  suffix: 'events' | 'events/summary';
  query: Record<string, string>;
}): Promise<NodeEventProxyResult> {
  const { target } = params;

  if (!target.dvr_server_id) return serviceError(503, 'Camera is not assigned to a node', target, false);
  if (target.node_enabled === false) return serviceError(503, 'Assigned node is disabled', target, false);
  if (!target.node_media_secret) return serviceError(503, 'Assigned node media secret is not configured', target, false);

  const bases = uniqueBases(target.node_internal_url, target.node_public_base_url);
  if (!bases.length) return serviceError(503, 'Assigned node URL is not configured', target, false);

  const token = signNodeMediaToken(target.node_media_secret, {
    camera_id: target.id,
    stream_name: target.stream_name,
    user_id: params.userId,
    scope: 'events'
  }, Math.max(60, Number(process.env.NODE_EVENT_TOKEN_TTL_SECONDS || 300)));

  const query = new URLSearchParams({ ...params.query, token });
  const timeoutMs = Math.max(1000, Math.min(60_000, Number(process.env.NODE_EVENT_PROXY_TIMEOUT_MS || 15_000)));
  let lastStatus: number | null = null;
  let lastBody = '';
  let lastError = 'Node event storage is unavailable';

  for (const base of bases) {
    const url = `${base}/cameras/${encodeURIComponent(target.stream_name)}/${params.suffix}?${query.toString()}`;
    try {
      const response = await fetchWithTimeout(url, timeoutMs);
      const body = await response.text();
      lastStatus = response.status;
      lastBody = body;

      if (response.ok || [400, 413, 422].includes(response.status)) {
        return {
          ok: response.ok,
          status: response.status,
          contentType: response.headers.get('content-type') || 'application/json',
          body: body || '{"items":[]}'
        };
      }

      if (response.status === 401 || response.status === 403) lastError = 'Node rejected the signed events token';
      else if (response.status === 404) lastError = 'Node event API is not installed';
      else lastError = `Node event API returned HTTP ${response.status}`;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
  }

  console.warn('[events-proxy] node request failed', {
    camera_id: target.id,
    stream_name: target.stream_name,
    node_id: target.dvr_server_id,
    node_status: target.node_status,
    http_status: lastStatus,
    error: lastError,
    response_prefix: lastBody.slice(0, 300)
  });

  return serviceError(503, 'Node event storage is unavailable', target, true, lastError);
}
