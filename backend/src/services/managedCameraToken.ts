import crypto from 'node:crypto';
import { config } from '../config.js';

const COMPACT_TOKEN_PREFIX = 'm1';
const LEGACY_TOKEN_PREFIX = 'mct1';
const COMPACT_BODY_BYTES = 20;
const COMPACT_MAC_BYTES = 12;
const COMPACT_TOTAL_BYTES = COMPACT_BODY_BYTES + COMPACT_MAC_BYTES;

export type ManagedCameraTokenPayload = {
  token_id: string;
  generation: number;
  type: 'managed-camera-access';
  version: 1 | 2;
};

function tokenSecret(): string {
  return String(process.env.MANAGED_CAMERA_TOKEN_SECRET || config.jwtSecret).trim();
}

function safeEqual(left: Buffer | string, right: Buffer | string): boolean {
  const leftBuffer = Buffer.isBuffer(left) ? left : Buffer.from(left);
  const rightBuffer = Buffer.isBuffer(right) ? right : Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function uuidToBytes(value: string): Buffer {
  const compact = String(value || '').replaceAll('-', '').toLowerCase();
  if (!/^[0-9a-f]{32}$/.test(compact)) throw new Error('Invalid managed token UUID');
  return Buffer.from(compact, 'hex');
}

function bytesToUuid(value: Buffer): string {
  if (value.length !== 16) throw new Error('Invalid managed token UUID bytes');
  const hex = value.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function compactMac(body: Buffer): Buffer {
  return crypto
    .createHmac('sha256', tokenSecret())
    .update(`${COMPACT_TOKEN_PREFIX}.`)
    .update(body)
    .digest()
    .subarray(0, COMPACT_MAC_BYTES);
}

function signCompactManagedCameraToken(tokenId: string, generation: number): string {
  if (!Number.isInteger(generation) || generation < 1 || generation > 0xffffffff) {
    throw new Error('Invalid managed token generation');
  }

  const body = Buffer.alloc(COMPACT_BODY_BYTES);
  uuidToBytes(tokenId).copy(body, 0);
  body.writeUInt32BE(generation, 16);
  const packed = Buffer.concat([body, compactMac(body)]);
  return `${COMPACT_TOKEN_PREFIX}.${packed.toString('base64url')}`;
}

function verifyCompactManagedCameraToken(rawToken: string): ManagedCameraTokenPayload | null {
  const parts = String(rawToken || '').trim().split('.');
  if (parts.length !== 2 || parts[0] !== COMPACT_TOKEN_PREFIX || !parts[1]) return null;

  try {
    const packed = Buffer.from(parts[1], 'base64url');
    if (packed.length !== COMPACT_TOTAL_BYTES) return null;

    const body = packed.subarray(0, COMPACT_BODY_BYTES);
    const suppliedMac = packed.subarray(COMPACT_BODY_BYTES);
    if (!safeEqual(suppliedMac, compactMac(body))) return null;

    const generation = body.readUInt32BE(16);
    if (generation < 1) return null;

    return {
      token_id: bytesToUuid(body.subarray(0, 16)),
      generation,
      type: 'managed-camera-access',
      version: 2
    };
  } catch {
    return null;
  }
}

function legacySignature(body: string): string {
  return crypto.createHmac('sha256', tokenSecret()).update(`${LEGACY_TOKEN_PREFIX}.${body}`).digest('base64url');
}

function verifyLegacyManagedCameraToken(rawToken: string): ManagedCameraTokenPayload | null {
  const parts = String(rawToken || '').trim().split('.');
  if (parts.length !== 3 || parts[0] !== LEGACY_TOKEN_PREFIX || !parts[1] || !parts[2]) return null;
  if (!safeEqual(parts[2], legacySignature(parts[1]))) return null;

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

export function signManagedCameraToken(tokenId: string, generation: number): string {
  return signCompactManagedCameraToken(tokenId, generation);
}

export function verifyManagedCameraToken(rawToken: string): ManagedCameraTokenPayload | null {
  const token = String(rawToken || '').trim();
  if (token.startsWith(`${COMPACT_TOKEN_PREFIX}.`)) return verifyCompactManagedCameraToken(token);
  if (token.startsWith(`${LEGACY_TOKEN_PREFIX}.`)) return verifyLegacyManagedCameraToken(token);
  return null;
}
