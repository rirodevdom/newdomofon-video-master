import crypto from 'node:crypto';
import { config } from '../config.js';

const TOKEN_PREFIX = 'mct1';

export type ManagedCameraTokenPayload = {
  token_id: string;
  generation: number;
  type: 'managed-camera-access';
  version: 1;
};

function tokenSecret(): string {
  return String(process.env.MANAGED_CAMERA_TOKEN_SECRET || config.jwtSecret).trim();
}

function safeEqual(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function signature(body: string): string {
  return crypto.createHmac('sha256', tokenSecret()).update(`${TOKEN_PREFIX}.${body}`).digest('base64url');
}

export function signManagedCameraToken(tokenId: string, generation: number): string {
  const payload: ManagedCameraTokenPayload = {
    token_id: tokenId,
    generation,
    type: 'managed-camera-access',
    version: 1
  };
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${TOKEN_PREFIX}.${body}.${signature(body)}`;
}

export function verifyManagedCameraToken(rawToken: string): ManagedCameraTokenPayload | null {
  const parts = String(rawToken || '').trim().split('.');
  if (parts.length !== 3 || parts[0] !== TOKEN_PREFIX || !parts[1] || !parts[2]) return null;
  if (!safeEqual(parts[2], signature(parts[1]))) return null;

  try {
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')) as Partial<ManagedCameraTokenPayload>;
    if (
      payload.type !== 'managed-camera-access' ||
      payload.version !== 1 ||
      typeof payload.token_id !== 'string' ||
      !/^[0-9a-f-]{36}$/i.test(payload.token_id) ||
      !Number.isInteger(payload.generation) ||
      Number(payload.generation) < 1
    ) {
      return null;
    }

    return payload as ManagedCameraTokenPayload;
  } catch {
    return null;
  }
}
