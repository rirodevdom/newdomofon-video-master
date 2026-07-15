import crypto from 'node:crypto';
import { config } from '../config.js';

const CIPHERTEXT_PREFIX = 'manual1';

function tokenSecret(): string {
  return String(process.env.MANAGED_CAMERA_TOKEN_SECRET || config.jwtSecret).trim();
}

function encryptionKey(): Buffer {
  return crypto
    .createHash('sha256')
    .update('newdomofon.manual-managed-token.v1\0')
    .update(tokenSecret())
    .digest();
}

export function validateManualManagedCameraToken(rawToken: unknown): string {
  const token = String(rawToken ?? '').trim();
  if (token.length < 16 || token.length > 255) {
    throw new Error('Ручное значение токена должно содержать от 16 до 255 символов');
  }
  if (/\s|[\u0000-\u001f\u007f]/u.test(token)) {
    throw new Error('Ручное значение токена не должно содержать пробелы или управляющие символы');
  }
  if (token.startsWith('m1.') || token.startsWith('mct1.')) {
    throw new Error('Префиксы m1. и mct1. зарезервированы для сгенерированных токенов');
  }
  return token;
}

export function manualManagedCameraTokenDigest(rawToken: string): string {
  return crypto
    .createHmac('sha256', tokenSecret())
    .update('newdomofon.manual-managed-token.lookup.v1\0')
    .update(String(rawToken || ''))
    .digest('hex');
}

export function encryptManualManagedCameraToken(rawToken: string): string {
  const token = validateManualManagedCameraToken(rawToken);
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', encryptionKey(), iv);
  cipher.setAAD(Buffer.from(CIPHERTEXT_PREFIX));
  const encrypted = Buffer.concat([cipher.update(token, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [
    CIPHERTEXT_PREFIX,
    iv.toString('base64url'),
    tag.toString('base64url'),
    encrypted.toString('base64url')
  ].join('.');
}

export function decryptManualManagedCameraToken(ciphertext: string): string {
  const parts = String(ciphertext || '').split('.');
  if (parts.length !== 4 || parts[0] !== CIPHERTEXT_PREFIX) {
    throw new Error('Invalid encrypted manual managed token');
  }
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    encryptionKey(),
    Buffer.from(parts[1], 'base64url')
  );
  decipher.setAAD(Buffer.from(CIPHERTEXT_PREFIX));
  decipher.setAuthTag(Buffer.from(parts[2], 'base64url'));
  return Buffer.concat([
    decipher.update(Buffer.from(parts[3], 'base64url')),
    decipher.final()
  ]).toString('utf8');
}
