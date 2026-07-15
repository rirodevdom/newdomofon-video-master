#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

SYSTEM_TOKEN_ID = "00000000-0000-4000-8000-000000000001"


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1), True


def replace_regex(text: str, pattern: str, replacement: str, label: str) -> tuple[str, bool]:
    if replacement in text:
        return text, False
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return updated, True


def patch_managed_routes(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    text, did = replace_once(
        text,
        "import { signManagedCameraToken } from '../services/managedCameraToken.js';",
        """import { signManagedCameraToken } from '../services/managedCameraToken.js';
import {
  decryptManualManagedCameraToken,
  encryptManualManagedCameraToken,
  manualManagedCameraTokenDigest,
  validateManualManagedCameraToken
} from '../services/manualManagedCameraToken.js';""",
        "manual token service import",
    )
    changed |= did

    old_schemas = """const createSchema = z.object({
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(500).optional().nullable(),
  scopes: z.array(scopeSchema).min(1).optional().default(['camera', 'events']),
  expires_at: z.string().trim().optional().nullable()
});
const updateSchema = z.object({
  name: z.string().trim().min(1).max(120).optional(),
  description: z.string().trim().max(500).optional().nullable(),
  scopes: z.array(scopeSchema).min(1).optional(),
  is_active: z.boolean().optional(),
  expires_at: z.string().trim().optional().nullable()
});"""
    new_schemas = """const createSchema = z.object({
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(500).optional().nullable(),
  scopes: z.array(scopeSchema).min(1).optional().default(['camera', 'events']),
  expires_at: z.string().trim().optional().nullable(),
  token_mode: z.enum(['generated', 'manual']).optional().default('generated'),
  token_value: z.string().optional().nullable(),
  auto_assign_new_cameras: z.boolean().optional().default(false)
});
const updateSchema = z.object({
  name: z.string().trim().min(1).max(120).optional(),
  description: z.string().trim().max(500).optional().nullable(),
  scopes: z.array(scopeSchema).min(1).optional(),
  is_active: z.boolean().optional(),
  expires_at: z.string().trim().optional().nullable(),
  auto_assign_new_cameras: z.boolean().optional()
});
const rotateSchema = z.object({ token_value: z.string().optional().nullable() });"""
    text, did = replace_once(text, old_schemas, new_schemas, "managed token schemas")
    changed |= did

    text, did = replace_once(
        text,
        "export const managedCameraTokensRouter = Router();",
        f"export const managedCameraTokensRouter = Router();\n\nconst SYSTEM_MANAGED_TOKEN_ID = '{SYSTEM_TOKEN_ID}';",
        "system token constant",
    )
    changed |= did

    old_type = """  description: string | null;
  generation: number;
  scopes: string[];"""
    new_type = """  description: string | null;
  token_mode: 'generated' | 'manual';
  manual_token_ciphertext: string | null;
  manual_token_digest: string | null;
  auto_assign_new_cameras: boolean;
  generation: number;
  scopes: string[];"""
    text, did = replace_once(text, old_type, new_type, "managed token row material")
    changed |= did

    old_serialize = """function serializeToken(row: ManagedTokenRow) {
  return {
    ...row,
    scopes: Array.isArray(row.scopes) ? row.scopes : [],
    assigned_cameras: Array.isArray(row.assigned_cameras) ? row.assigned_cameras : [],
    token: signManagedCameraToken(row.id, Number(row.generation))
  };
}"""
    new_serialize = """function rawManagedToken(row: ManagedTokenRow): string {
  return row.token_mode === 'manual'
    ? decryptManualManagedCameraToken(String(row.manual_token_ciphertext || ''))
    : signManagedCameraToken(row.id, Number(row.generation));
}

function serializeToken(row: ManagedTokenRow) {
  const { manual_token_ciphertext: _ciphertext, manual_token_digest: _digest, ...safeRow } = row;
  return {
    ...safeRow,
    scopes: Array.isArray(row.scopes) ? row.scopes : [],
    assigned_cameras: Array.isArray(row.assigned_cameras) ? row.assigned_cameras : [],
    token: rawManagedToken(row)
  };
}"""
    text, did = replace_once(text, old_serialize, new_serialize, "managed token serializer")
    changed |= did

    text = text.replace(
        "SELECT id, name, description, generation, scopes, is_active, expires_at,",
        "SELECT id, name, description, token_mode, manual_token_ciphertext, manual_token_digest,\n             auto_assign_new_cameras, generation, scopes, is_active, expires_at,",
    )
    text = text.replace(
        "SELECT t.id, t.name, t.description, t.generation, t.scopes, t.is_active,",
        "SELECT t.id, t.name, t.description, t.token_mode, t.manual_token_ciphertext,\n             t.manual_token_digest, t.auto_assign_new_cameras, t.generation, t.scopes, t.is_active,",
    )
    text = text.replace(
        "RETURNING id, name, description, generation, scopes, is_active, expires_at,",
        "RETURNING id, name, description, token_mode, manual_token_ciphertext, manual_token_digest,\n                auto_assign_new_cameras, generation, scopes, is_active, expires_at,",
    )

    unique_anchor = """async function ensureUniqueName(name: string, excludedId?: string) {
  const result = await query(
    `SELECT 1
       FROM managed_camera_tokens
      WHERE lower(name) = lower($1)
        AND ($2::uuid IS NULL OR id <> $2::uuid)
      LIMIT 1`,
    [name, excludedId || null]
  );
  if (result.rows.length) {
    const error = new Error('Токен с таким именем уже существует') as Error & { status?: number };
    error.status = 409;
    throw error;
  }
}"""
    unique_block = unique_anchor + """

async function ensureUniqueManualValue(rawToken: string, excludedId?: string) {
  const digest = manualManagedCameraTokenDigest(rawToken);
  const result = await query(
    `SELECT 1
       FROM managed_camera_tokens
      WHERE manual_token_digest = $1
        AND ($2::uuid IS NULL OR id <> $2::uuid)
      LIMIT 1`,
    [digest, excludedId || null]
  );
  if (result.rows.length) {
    const error = new Error('Такое ручное значение токена уже используется') as Error & { status?: number };
    error.status = 409;
    throw error;
  }
}"""
    text, did = replace_once(text, unique_anchor, unique_block, "manual token uniqueness helper")
    changed |= did

    create_pattern = (
        r"managedCameraTokensRouter\.post\('/managed-camera-tokens', asyncHandler\(async \(req, res\) => \{"
        r"[\s\S]*?"
        r"\n\}\)\);\n\nmanagedCameraTokensRouter\.patch\('/managed-camera-tokens/:tokenId'"
    )
    create_replacement = """managedCameraTokensRouter.post('/managed-camera-tokens', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!authReq.user) return res.status(401).json({ error: 'Unauthorized' });
  const body = createSchema.parse(req.body || {});
  await ensureUniqueName(body.name);

  const expiresAt = parseExpiresAt(body.expires_at);
  if (expiresAt && expiresAt.getTime() <= Date.now()) {
    return res.status(400).json({ error: 'Срок действия должен быть в будущем' });
  }
  if (body.auto_assign_new_cameras && !body.scopes.includes('camera')) {
    return res.status(400).json({ error: 'Автопривязка требует право «Видео»' });
  }

  let manualCiphertext: string | null = null;
  let manualDigest: string | null = null;
  if (body.token_mode === 'manual') {
    const rawToken = validateManualManagedCameraToken(body.token_value);
    await ensureUniqueManualValue(rawToken);
    manualCiphertext = encryptManualManagedCameraToken(rawToken);
    manualDigest = manualManagedCameraTokenDigest(rawToken);
  }

  const result = await query<ManagedTokenRow>(
    `INSERT INTO managed_camera_tokens(
       id, name, description, token_mode, manual_token_ciphertext, manual_token_digest,
       auto_assign_new_cameras, generation, scopes, is_active, expires_at, created_by
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,1,$8,true,$9,$10)
     RETURNING id, name, description, token_mode, manual_token_ciphertext, manual_token_digest,
               auto_assign_new_cameras, generation, scopes, is_active, expires_at,
               created_by, last_used_at, created_at, updated_at`,
    [
      crypto.randomUUID(), body.name, body.description || null, body.token_mode,
      manualCiphertext, manualDigest, body.auto_assign_new_cameras,
      body.scopes, expiresAt, authReq.user.id
    ]
  );

  res.status(201).json({ item: serializeToken({ ...result.rows[0], assigned_cameras: [] }) });
}));

managedCameraTokensRouter.patch('/managed-camera-tokens/:tokenId'"""
    text, did = replace_regex(text, create_pattern, create_replacement, "managed token create route")
    changed |= did

    update_pattern = (
        r"managedCameraTokensRouter\.patch\('/managed-camera-tokens/:tokenId', asyncHandler\(async \(req, res\) => \{"
        r"[\s\S]*?"
        r"\n\}\)\);\n\nmanagedCameraTokensRouter\.post\('/managed-camera-tokens/:tokenId/rotate'"
    )
    update_replacement = """managedCameraTokensRouter.patch('/managed-camera-tokens/:tokenId', asyncHandler(async (req, res) => {
  const tokenId = z.string().uuid().parse(req.params.tokenId);
  const body = updateSchema.parse(req.body || {});
  const current = await loadToken(tokenId);
  if (!current) return res.status(404).json({ error: 'Токен не найден' });
  if (tokenId === SYSTEM_MANAGED_TOKEN_ID) {
    return res.status(409).json({ error: 'Внутренний системный токен нельзя изменять' });
  }

  const name = body.name ?? current.name;
  const description = body.description === undefined ? current.description : (body.description || null);
  const scopes = body.scopes ?? current.scopes;
  const isActive = body.is_active ?? current.is_active;
  const expiresAt = body.expires_at === undefined ? current.expires_at : parseExpiresAt(body.expires_at);
  const autoAssign = body.auto_assign_new_cameras ?? current.auto_assign_new_cameras;

  if (autoAssign && !scopes.includes('camera')) {
    return res.status(400).json({ error: 'Автопривязка требует право «Видео»' });
  }
  if (body.name !== undefined) await ensureUniqueName(name, tokenId);

  const result = await query<ManagedTokenRow>(
    `UPDATE managed_camera_tokens
        SET name = $2,
            description = $3,
            scopes = $4,
            is_active = $5,
            expires_at = $6,
            auto_assign_new_cameras = $7
      WHERE id = $1
      RETURNING id, name, description, token_mode, manual_token_ciphertext, manual_token_digest,
                auto_assign_new_cameras, generation, scopes, is_active, expires_at,
                created_by, last_used_at, created_at, updated_at`,
    [tokenId, name, description, scopes, isActive, expiresAt, autoAssign]
  );

  res.json({ item: serializeToken({ ...result.rows[0], assigned_cameras: current.assigned_cameras || [] }) });
}));

managedCameraTokensRouter.post('/managed-camera-tokens/:tokenId/rotate'"""
    text, did = replace_regex(text, update_pattern, update_replacement, "managed token update route")
    changed |= did

    rotate_pattern = (
        r"managedCameraTokensRouter\.post\('/managed-camera-tokens/:tokenId/rotate', asyncHandler\(async \(req, res\) => \{"
        r"[\s\S]*?"
        r"\n\}\)\);\n\nmanagedCameraTokensRouter\.delete\('/managed-camera-tokens/:tokenId'"
    )
    rotate_replacement = """managedCameraTokensRouter.post('/managed-camera-tokens/:tokenId/rotate', asyncHandler(async (req, res) => {
  const tokenId = z.string().uuid().parse(req.params.tokenId);
  const body = rotateSchema.parse(req.body || {});
  const current = await loadToken(tokenId);
  if (!current) return res.status(404).json({ error: 'Токен не найден' });
  if (tokenId === SYSTEM_MANAGED_TOKEN_ID) {
    return res.status(409).json({ error: 'Внутренний системный токен нельзя ротировать' });
  }

  let result;
  if (current.token_mode === 'manual') {
    const rawToken = validateManualManagedCameraToken(body.token_value);
    const digest = manualManagedCameraTokenDigest(rawToken);
    if (digest === current.manual_token_digest) {
      return res.status(400).json({ error: 'Новое значение ручного токена совпадает с текущим' });
    }
    await ensureUniqueManualValue(rawToken, tokenId);
    result = await query<ManagedTokenRow>(
      `UPDATE managed_camera_tokens
          SET generation = generation + 1,
              manual_token_ciphertext = $2,
              manual_token_digest = $3,
              is_active = true,
              last_used_at = NULL
        WHERE id = $1
        RETURNING id, name, description, token_mode, manual_token_ciphertext, manual_token_digest,
                  auto_assign_new_cameras, generation, scopes, is_active, expires_at,
                  created_by, last_used_at, created_at, updated_at`,
      [tokenId, encryptManualManagedCameraToken(rawToken), digest]
    );
  } else {
    result = await query<ManagedTokenRow>(
      `UPDATE managed_camera_tokens
          SET generation = generation + 1,
              is_active = true,
              last_used_at = NULL
        WHERE id = $1
        RETURNING id, name, description, token_mode, manual_token_ciphertext, manual_token_digest,
                  auto_assign_new_cameras, generation, scopes, is_active, expires_at,
                  created_by, last_used_at, created_at, updated_at`,
      [tokenId]
    );
  }

  res.json({ item: serializeToken({ ...result.rows[0], assigned_cameras: current.assigned_cameras || [] }) });
}));

managedCameraTokensRouter.delete('/managed-camera-tokens/:tokenId'"""
    text, did = replace_regex(text, rotate_pattern, rotate_replacement, "managed token rotate route")
    changed |= did

    text, did = replace_once(
        text,
        "  const rawToken = signManagedCameraToken(token.id, Number(token.generation));",
        "  const rawToken = rawManagedToken(token);",
        "manual token camera links",
    )
    changed |= did

    required = (
        "token_mode: z.enum(['generated', 'manual'])",
        "auto_assign_new_cameras",
        "manualManagedCameraTokenDigest",
        "const rawToken = rawManagedToken(token);",
    )
    missing = [item for item in required if item not in text]
    if missing:
        raise RuntimeError(f"managed routes markers missing: {missing}")

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_internal_resolver(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    text, did = replace_once(
        text,
        "import { verifyManagedCameraToken } from '../services/managedCameraToken.js';",
        """import { verifyManagedCameraToken } from '../services/managedCameraToken.js';
import { manualManagedCameraTokenDigest } from '../services/manualManagedCameraToken.js';""",
        "manual resolver import",
    )
    changed |= did

    pattern = (
        r"  // Managed tokens are master-owned, reusable and explicitly assigned to cameras\."
        r"[\s\S]*?"
        r"\n  // Compatibility path for already-issued camera tokens\."
    )
    replacement = """  // Managed tokens are master-owned, reusable and explicitly assigned to cameras.
  // Generated m1/mct1 values are verified cryptographically. Arbitrary manual
  // values are looked up by HMAC digest, so plaintext is never stored in the DB.
  const managedPayload = verifyManagedCameraToken(body.token);
  const streamResult = streamNameSchema.safeParse(String(body.stream_name || '').trim());
  let managedResult: { rows: ManagedCameraNodeRow[] } | null = null;

  if (managedPayload) {
    if (!streamResult.success) return res.status(400).json({ error: 'stream_name is required for managed tokens' });
    managedResult = await query<ManagedCameraNodeRow>(
      `SELECT t.id AS managed_token_id,
              t.name AS managed_token_name,
              t.generation AS managed_token_generation,
              t.scopes AS managed_token_scopes,
              t.is_active AS managed_token_active,
              t.expires_at AS managed_token_expires_at,
              t.created_by AS managed_token_created_by,
              c.id AS camera_id,
              c.name AS camera_name,
              c.stream_name,
              c.is_enabled AS camera_enabled,
              ds.id AS node_id,
              ds.name AS node_name,
              ds.is_enabled AS node_enabled,
              ds.internal_url AS node_internal_url,
              ds.base_url AS node_base_url,
              ds.public_base_url AS node_public_url,
              ds.media_secret AS node_media_secret
         FROM managed_camera_tokens t
         JOIN managed_camera_token_cameras mtc ON mtc.token_id = t.id
         JOIN cameras c ON c.id = mtc.camera_id
         JOIN dvr_servers ds ON ds.id = c.dvr_server_id
        WHERE t.token_mode = 'generated'
          AND t.id = $1
          AND t.generation = $2
          AND c.stream_name = $3
        LIMIT 1`,
      [managedPayload.token_id, managedPayload.generation, streamResult.data]
    );
  } else if (streamResult.success) {
    managedResult = await query<ManagedCameraNodeRow>(
      `SELECT t.id AS managed_token_id,
              t.name AS managed_token_name,
              t.generation AS managed_token_generation,
              t.scopes AS managed_token_scopes,
              t.is_active AS managed_token_active,
              t.expires_at AS managed_token_expires_at,
              t.created_by AS managed_token_created_by,
              c.id AS camera_id,
              c.name AS camera_name,
              c.stream_name,
              c.is_enabled AS camera_enabled,
              ds.id AS node_id,
              ds.name AS node_name,
              ds.is_enabled AS node_enabled,
              ds.internal_url AS node_internal_url,
              ds.base_url AS node_base_url,
              ds.public_base_url AS node_public_url,
              ds.media_secret AS node_media_secret
         FROM managed_camera_tokens t
         JOIN managed_camera_token_cameras mtc ON mtc.token_id = t.id
         JOIN cameras c ON c.id = mtc.camera_id
         JOIN dvr_servers ds ON ds.id = c.dvr_server_id
        WHERE t.token_mode = 'manual'
          AND t.manual_token_digest = $1
          AND c.stream_name = $2
        LIMIT 1`,
      [manualManagedCameraTokenDigest(body.token), streamResult.data]
    );
  }

  const camera = managedResult?.rows[0];
  if (camera) {
    if (!camera.managed_token_active) return res.status(401).json({ error: 'Managed token is disabled' });
    if (camera.managed_token_expires_at && new Date(camera.managed_token_expires_at).getTime() <= Date.now()) {
      return res.status(401).json({ error: 'Managed token expired' });
    }
    if (!camera.camera_enabled || !camera.node_enabled || !camera.node_media_secret) {
      return res.status(404).json({ error: 'Camera or assigned node is unavailable' });
    }

    const requiredScope = body.upstream_scope === 'events' ? 'events' : 'camera';
    if (!Array.isArray(camera.managed_token_scopes) || !camera.managed_token_scopes.includes(requiredScope)) {
      return res.status(403).json({ error: `Managed token does not allow ${requiredScope}` });
    }

    await query(
      `UPDATE managed_camera_tokens
          SET last_used_at = now()
        WHERE id = $1
          AND (last_used_at IS NULL OR last_used_at < now() - interval '5 minutes')`,
      [camera.managed_token_id]
    ).catch(() => undefined);

    return sendResolved(
      res,
      camera,
      body.upstream_scope,
      camera.managed_token_created_by || `managed:${camera.managed_token_id}`,
      'managed',
      { id: camera.managed_token_id, name: camera.managed_token_name }
    );
  }

  if (managedPayload) return res.status(403).json({ error: 'Token is not assigned to this camera' });

  // Compatibility path for already-issued camera tokens."""
    text, did = replace_regex(text, pattern, replacement, "internal managed token resolver")
    changed |= did

    if "manualManagedCameraTokenDigest(body.token)" not in text:
        raise RuntimeError("manual resolver marker missing")
    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_admin_player(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    text, did = replace_once(
        text,
        "import { signManagedCameraToken } from '../services/managedCameraToken.js';",
        """import { signManagedCameraToken } from '../services/managedCameraToken.js';
import { decryptManualManagedCameraToken } from '../services/manualManagedCameraToken.js';""",
        "manual admin player import",
    )
    changed |= did

    text, did = replace_once(
        text,
        """  token_name: string;
  token_generation: number;""",
        """  token_name: string;
  token_mode: 'generated' | 'manual';
  token_manual_ciphertext: string | null;
  token_generation: number;""",
        "admin player token material type",
    )
    changed |= did

    text, did = replace_once(
        text,
        """            token.name AS token_name,
            token.generation AS token_generation,""",
        """            token.name AS token_name,
            token.token_mode AS token_mode,
            token.manual_token_ciphertext AS token_manual_ciphertext,
            token.generation AS token_generation,""",
        "admin player token material select",
    )
    changed |= did

    metadata_anchor = """function managedTokenMetadata(row: ManagedPlayerRow) {
  return {
    id: row.token_id,
    name: row.token_name,
    system: row.token_id === SYSTEM_MANAGED_TOKEN_ID,
    expires_at: row.token_expires_at,
    assignment_created_at: row.assignment_created_at
  };
}"""
    metadata_block = metadata_anchor + """

function rawManagedPlayerToken(row: ManagedPlayerRow): string {
  return row.token_mode === 'manual'
    ? decryptManualManagedCameraToken(String(row.token_manual_ciphertext || ''))
    : signManagedCameraToken(row.token_id, Number(row.token_generation));
}"""
    text, did = replace_once(text, metadata_anchor, metadata_block, "admin player token helper")
    changed |= did

    text = text.replace(
        "const rawToken = signManagedCameraToken(access.token_id, Number(access.token_generation));",
        "const rawToken = rawManagedPlayerToken(access);",
    )
    if text.count("const rawToken = rawManagedPlayerToken(access);") != 2:
        raise RuntimeError("expected two managed admin player token calls")

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_admin_view(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    old_form = """          <v-row>
            <v-col cols="12" md="3"><v-text-field v-model="managedTokenForm.name" label="Название токена" placeholder="SmartYard Иваново" /></v-col>
            <v-col cols="12" md="4"><v-text-field v-model="managedTokenForm.description" label="Описание" placeholder="Для интеграции или клиента" /></v-col>
            <v-col cols="12" md="3"><v-text-field v-model="managedTokenForm.expires_at" type="datetime-local" label="Истекает (необязательно)" /></v-col>
            <v-col cols="6" md="1"><v-switch v-model="managedTokenForm.allow_camera" color="primary" label="Видео" hide-details /></v-col>
            <v-col cols="6" md="1"><v-switch v-model="managedTokenForm.allow_events" color="primary" label="События" hide-details /></v-col>
          </v-row>
          <v-btn color="primary" :loading="creatingManagedToken" :disabled="!managedTokenForm.name.trim() || (!managedTokenForm.allow_camera && !managedTokenForm.allow_events)" @click="createManagedToken">"""
    new_form = """          <v-row>
            <v-col cols="12" md="3"><v-text-field v-model="managedTokenForm.name" label="Название токена" placeholder="SmartYard Иваново" /></v-col>
            <v-col cols="12" md="3"><v-text-field v-model="managedTokenForm.description" label="Описание" placeholder="Для интеграции или клиента" /></v-col>
            <v-col cols="12" md="3"><v-text-field v-model="managedTokenForm.expires_at" type="datetime-local" label="Истекает (необязательно)" /></v-col>
            <v-col cols="12" md="3"><v-select v-model="managedTokenForm.token_mode" :items="managedTokenModes" item-title="title" item-value="value" label="Значение токена" /></v-col>
            <v-col v-if="managedTokenForm.token_mode === 'manual'" cols="12" md="6">
              <v-text-field v-model="managedTokenForm.token_value" label="Ручное значение токена" hint="От 16 до 255 символов, без пробелов. Это значение попадёт в ссылки без автогенерации." persistent-hint autocomplete="off" />
            </v-col>
            <v-col cols="6" md="2"><v-switch v-model="managedTokenForm.allow_camera" color="primary" label="Видео" hide-details /></v-col>
            <v-col cols="6" md="2"><v-switch v-model="managedTokenForm.allow_events" color="primary" label="События" hide-details /></v-col>
            <v-col cols="12" md="4"><v-switch v-model="managedTokenForm.auto_assign_new_cameras" color="primary" label="Автоматически назначать новым камерам" hint="Токен будет добавляться к каждой новой камере. Существующие камеры не меняются." persistent-hint /></v-col>
          </v-row>
          <v-btn color="primary" :loading="creatingManagedToken" :disabled="!managedTokenForm.name.trim() || (!managedTokenForm.allow_camera && !managedTokenForm.allow_events) || (managedTokenForm.token_mode === 'manual' && managedTokenForm.token_value.trim().length < 16)" @click="createManagedToken">"""
    text, did = replace_once(text, old_form, new_form, "managed token creation form")
    changed |= did

    text, did = replace_once(
        text,
        "<thead><tr><th>Название</th><th>Права</th><th>Состояние</th><th>Камеры</th><th>Истекает</th><th>Последнее использование</th><th></th></tr></thead>",
        "<thead><tr><th>Название</th><th>Режим</th><th>Права</th><th>Авто новым камерам</th><th>Состояние</th><th>Камеры</th><th>Истекает</th><th>Последнее использование</th><th></th></tr></thead>",
        "managed token table header",
    )
    changed |= did

    text, did = replace_once(
        text,
        """                </td>
                <td><v-chip v-for="scope in token.scopes" :key="scope" size="x-small" class="mr-1" variant="tonal">{{ scope === 'camera' ? 'Видео' : 'События' }}</v-chip></td>
                <td><v-chip size="small" :color="managedTokenStatus(token).color">{{ managedTokenStatus(token).text }}</v-chip></td>""",
        """                </td>
                <td><v-chip size="small" variant="tonal">{{ token.token_mode === 'manual' ? 'Ручной' : 'Сгенерированный' }}</v-chip></td>
                <td><v-chip v-for="scope in token.scopes" :key="scope" size="x-small" class="mr-1" variant="tonal">{{ scope === 'camera' ? 'Видео' : 'События' }}</v-chip></td>
                <td>
                  <v-switch
                    v-model="token.auto_assign_new_cameras"
                    color="primary"
                    density="compact"
                    hide-details
                    :disabled="isSystemManagedToken(token) || !token.scopes?.includes('camera')"
                    @update:model-value="toggleManagedTokenAutoAssign(token)"
                  />
                </td>
                <td><v-chip size="small" :color="managedTokenStatus(token).color">{{ managedTokenStatus(token).text }}</v-chip></td>""",
        "managed token table mode and automatic assignment",
    )
    changed |= did

    text, did = replace_once(
        text,
        """                  <v-btn size="small" variant="text" icon="mdi-content-copy" title="Копировать" @click="copyText(token.token)" />
                  <v-btn size="small" variant="text" icon="mdi-refresh" title="Ротировать" @click="rotateManagedToken(token)" />
                  <v-btn size="small" variant="text" :icon="token.is_active ? 'mdi-pause-circle-outline' : 'mdi-play-circle-outline'" :title="token.is_active ? 'Отключить' : 'Включить'" @click="toggleManagedToken(token)" />
                  <v-btn size="small" color="error" variant="text" icon="mdi-delete-outline" title="Удалить" @click="removeManagedToken(token)" />""",
        """                  <v-btn size="small" variant="text" icon="mdi-content-copy" title="Копировать" @click="copyText(token.token)" />
                  <v-btn v-if="!isSystemManagedToken(token)" size="small" variant="text" icon="mdi-refresh" title="Ротировать" @click="rotateManagedToken(token)" />
                  <v-btn v-if="!isSystemManagedToken(token)" size="small" variant="text" :icon="token.is_active ? 'mdi-pause-circle-outline' : 'mdi-play-circle-outline'" :title="token.is_active ? 'Отключить' : 'Включить'" @click="toggleManagedToken(token)" />
                  <v-btn v-if="!isSystemManagedToken(token)" size="small" color="error" variant="text" icon="mdi-delete-outline" title="Удалить" @click="removeManagedToken(token)" />""",
        "protect system token UI actions",
    )
    changed |= did

    text = text.replace(
        '<tr v-if="!managedTokens.length"><td colspan="7"',
        '<tr v-if="!managedTokens.length"><td colspan="9"',
    )

    text, did = replace_once(
        text,
        "const roles = ['super_admin', 'operator', 'viewer', 'installer'];",
        f"""const SYSTEM_MANAGED_TOKEN_ID = '{SYSTEM_TOKEN_ID}';
const roles = ['super_admin', 'operator', 'viewer', 'installer'];
const managedTokenModes = [
  {{ title: 'Сгенерировать автоматически', value: 'generated' }},
  {{ title: 'Задать вручную', value: 'manual' }}
];""",
        "managed token mode options",
    )
    changed |= did

    text, did = replace_once(
        text,
        "const managedTokenForm = reactive({ name: '', description: '', expires_at: '', allow_camera: true, allow_events: true });",
        "const managedTokenForm = reactive({ name: '', description: '', expires_at: '', token_mode: 'generated', token_value: '', auto_assign_new_cameras: false, allow_camera: true, allow_events: true });",
        "managed token form state",
    )
    changed |= did

    status_anchor = """function managedTokenStatus(token: any) {
  if (!token.is_active) return { text: 'отключён', color: 'error' };
  if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) return { text: 'истёк', color: 'warning' };
  return { text: 'активен', color: 'success' };
}"""
    status_block = status_anchor + """

function isSystemManagedToken(token: any) {
  return token?.id === SYSTEM_MANAGED_TOKEN_ID;
}"""
    text, did = replace_once(text, status_anchor, status_block, "system token UI helper")
    changed |= did

    text, did = replace_once(
        text,
        """      scopes,
      expires_at: managedTokenForm.expires_at ? new Date(managedTokenForm.expires_at).toISOString() : null
    });""",
        """      scopes,
      expires_at: managedTokenForm.expires_at ? new Date(managedTokenForm.expires_at).toISOString() : null,
      token_mode: managedTokenForm.token_mode,
      token_value: managedTokenForm.token_mode === 'manual' ? managedTokenForm.token_value.trim() : null,
      auto_assign_new_cameras: managedTokenForm.auto_assign_new_cameras
    });""",
        "managed token create payload",
    )
    changed |= did

    text, did = replace_once(
        text,
        "Object.assign(managedTokenForm, { name: '', description: '', expires_at: '', allow_camera: true, allow_events: true });",
        "Object.assign(managedTokenForm, { name: '', description: '', expires_at: '', token_mode: 'generated', token_value: '', auto_assign_new_cameras: false, allow_camera: true, allow_events: true });",
        "managed token form reset",
    )
    changed |= did

    old_rotate = """async function rotateManagedToken(token: any) {
  if (!confirm(`Ротировать токен "${token.name}"? Все старые ссылки с ним перестанут работать.`)) return;
  try {
    const response = await api.post(`/tokens/managed-camera-tokens/${token.id}/rotate`, {});
    createdManagedToken.value = response.data.item;
    notify('Токен ротирован');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка ротации токена', 'error');
  }
}"""
    new_rotate = """async function rotateManagedToken(token: any) {
  let payload: Record<string, unknown> = {};
  if (token.token_mode === 'manual') {
    const value = prompt(`Введите новое ручное значение для токена "${token.name}". Минимум 16 символов, без пробелов.`);
    if (value === null) return;
    payload = { token_value: value.trim() };
  } else if (!confirm(`Ротировать токен "${token.name}"? Все старые ссылки с ним перестанут работать.`)) {
    return;
  }
  try {
    const response = await api.post(`/tokens/managed-camera-tokens/${token.id}/rotate`, payload);
    createdManagedToken.value = response.data.item;
    notify('Токен ротирован');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка ротации токена', 'error');
  }
}"""
    text, did = replace_once(text, old_rotate, new_rotate, "manual token rotation UI")
    changed |= did

    toggle_anchor = """async function toggleManagedToken(token: any) {
  try {
    await api.patch(`/tokens/managed-camera-tokens/${token.id}`, { is_active: !token.is_active });
    notify(token.is_active ? 'Токен отключён' : 'Токен включён');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка изменения токена', 'error');
  }
}"""
    toggle_block = toggle_anchor + """

async function toggleManagedTokenAutoAssign(token: any) {
  try {
    await api.patch(`/tokens/managed-camera-tokens/${token.id}`, {
      auto_assign_new_cameras: Boolean(token.auto_assign_new_cameras)
    });
    notify(token.auto_assign_new_cameras
      ? 'Токен будет автоматически назначаться новым камерам'
      : 'Автопривязка токена к новым камерам отключена');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка изменения автопривязки', 'error');
    await loadTokens();
  }
}"""
    text, did = replace_once(text, toggle_anchor, toggle_block, "auto assignment toggle UI")
    changed |= did

    required = (
        "managedTokenForm.token_mode",
        "auto_assign_new_cameras",
        "toggleManagedTokenAutoAssign",
        "token.token_mode === 'manual'",
    )
    missing = [item for item in required if item not in text]
    if missing:
        raise RuntimeError(f"admin view markers missing: {missing}")

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()

    targets = {
        "backend/src/routes/managedCameraTokens.ts": patch_managed_routes,
        "backend/src/routes/internalSmartYard.ts": patch_internal_resolver,
        "backend/src/routes/managedAdminPlayer.ts": patch_admin_player,
        "frontend/src/views/AdminView.vue": patch_admin_view,
    }

    changed_files: list[str] = []
    for relative, patcher in targets.items():
        path = root / relative
        if not path.is_file():
            raise SystemExit(f"Required source file is missing: {path}")
        if patcher(path):
            changed_files.append(relative)

    print("Manual/automatic managed-token patch applied")
    if changed_files:
        for item in changed_files:
            print(f"  changed: {item}")
    else:
        print("  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
