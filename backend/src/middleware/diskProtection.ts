import fs from 'node:fs';
import type { NextFunction, Request, Response } from 'express';

export type MasterDiskState = {
  ok?: boolean;
  state: 'ok' | 'warning' | 'critical' | 'unknown';
  reason?: string;
  worst_path?: string;
  total_bytes?: number;
  available_bytes?: number;
  used_percent?: number;
  inode_free_percent?: number;
  required_start_bytes?: number;
  required_resume_bytes?: number;
  checked_at?: string;
  error?: string;
};

const stateFile = process.env.MASTER_DISK_STATE_FILE || '/run/newdomofon-video/master-disk-state.json';
const criticalMarker = process.env.MASTER_DISK_CRITICAL_MARKER || '/run/newdomofon-video/master-disk-critical';

function parseStateFile(file: string): MasterDiskState | null {
  try {
    const raw = fs.readFileSync(file, 'utf8');
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const state = String(parsed.state || 'unknown');
    return {
      ...parsed,
      state: state === 'ok' || state === 'warning' || state === 'critical' ? state : 'unknown'
    } as MasterDiskState;
  } catch {
    return null;
  }
}

export function getMasterDiskState(): MasterDiskState {
  const state = parseStateFile(stateFile);
  if (state) return state;
  if (fs.existsSync(criticalMarker)) {
    return {
      ok: false,
      state: 'critical',
      reason: 'critical_marker_present',
      error: 'Disk guard state file is unavailable'
    };
  }
  return {
    ok: true,
    state: 'unknown',
    reason: 'disk_guard_not_initialized'
  };
}

function isMutatingMethod(method: string): boolean {
  return ['POST', 'PUT', 'PATCH', 'DELETE'].includes(method.toUpperCase());
}

function isReadOnlyMutation(pathname: string): boolean {
  return pathname === '/api/auth/login'
    || pathname.startsWith('/api/internal/smartyard')
    || pathname.startsWith('/api/internal/events/onvif')
    || pathname.startsWith('/api/internal/onvif-events');
}

export function diskProtectionMiddleware(req: Request, res: Response, next: NextFunction) {
  if (!isMutatingMethod(req.method) || isReadOnlyMutation(req.path)) return next();
  if (!fs.existsSync(criticalMarker)) return next();

  const disk = getMasterDiskState();
  res.setHeader('retry-after', '60');
  return res.status(507).json({
    error: 'Master is in read-only mode because disk space is critically low',
    code: 'MASTER_DISK_CRITICAL',
    retryable: true,
    disk
  });
}
