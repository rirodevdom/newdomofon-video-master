export type CameraEventRecord = {
  id?: string;
  camera_id?: string;
  stream_name?: string;
  event_type?: string;
  event_state?: unknown;
  topic?: string | null;
  source_name?: string | null;
  occurred_at?: string;
  created_at?: string;
  data?: Record<string, unknown>;
  [key: string]: unknown;
};

function isActiveState(value: unknown): boolean {
  return ['1', 'true', 'on', 'active', 'start', 'started'].includes(
    String(value ?? '').trim().toLowerCase()
  );
}

function logicalKey(event: CameraEventRecord): string {
  const type = String(event.event_type || 'unknown').toLowerCase();
  if (type === 'motion') return 'motion';
  return [type, event.source_name || '', event.topic || ''].join('|');
}

export function logicalEventView(
  rawItems: CameraEventRecord[],
  options: { includeInactive?: boolean; dedupMs?: number } = {}
): CameraEventRecord[] {
  const includeInactive = options.includeInactive === true;
  const configuredDedupMs = Number(options.dedupMs ?? 2000);
  const dedupMs = Number.isFinite(configuredDedupMs)
    ? Math.max(100, Math.min(10_000, Math.trunc(configuredDedupMs)))
    : 2000;
  const lastByKey = new Map<string, number>();
  const items: CameraEventRecord[] = [];

  for (const event of rawItems) {
    const timestamp = Date.parse(String(event.occurred_at || event.created_at || ''));
    if (!Number.isFinite(timestamp)) continue;

    if (!includeInactive && event.event_state !== null && event.event_state !== undefined && !isActiveState(event.event_state)) {
      continue;
    }

    const key = logicalKey(event);
    const previous = lastByKey.get(key);
    if (previous !== undefined && timestamp - previous <= dedupMs) continue;
    lastByKey.set(key, timestamp);

    items.push(event);
  }

  return items;
}
