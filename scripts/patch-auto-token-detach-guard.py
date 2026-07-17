#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

SYSTEM_TOKEN_ID = "00000000-0000-4000-8000-000000000001"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    path = Path(args.project_dir).resolve() / "backend/src/routes/managedCameraTokens.ts"
    if not path.is_file():
        raise SystemExit(f"Managed token route is missing: {path}")

    text = path.read_text(encoding="utf-8")
    marker = "Отключите автоматическое назначение токена всем камерам перед ручной отвязкой"
    if marker in text:
        print("Automatic token detach guard already applied")
        return

    old = """managedCameraTokensRouter.delete('/managed-camera-tokens/:tokenId/cameras/:cameraId', asyncHandler(async (req, res) => {
  const tokenId = z.string().uuid().parse(req.params.tokenId);
  const cameraId = z.string().uuid().parse(req.params.cameraId);
  await query(
    'DELETE FROM managed_camera_token_cameras WHERE token_id = $1 AND camera_id = $2',
    [tokenId, cameraId]
  );
  res.status(204).end();
}));"""
    new = f"""managedCameraTokensRouter.delete('/managed-camera-tokens/:tokenId/cameras/:cameraId', asyncHandler(async (req, res) => {{
  const tokenId = z.string().uuid().parse(req.params.tokenId);
  const cameraId = z.string().uuid().parse(req.params.cameraId);
  const token = await loadToken(tokenId);
  if (!token) return res.status(404).json({{ error: 'Токен не найден' }});
  if (tokenId === '{SYSTEM_TOKEN_ID}') {{
    return res.status(409).json({{ error: 'Внутренний системный fallback управляется автоматически' }});
  }}
  if (token.auto_assign_new_cameras) {{
    return res.status(409).json({{
      error: 'Отключите автоматическое назначение токена всем камерам перед ручной отвязкой'
    }});
  }}
  await query(
    'DELETE FROM managed_camera_token_cameras WHERE token_id = $1 AND camera_id = $2',
    [tokenId, cameraId]
  );
  res.status(204).end();
}}));"""

    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected one camera token detach route, found {count}")

    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Automatic token detach guard applied")


if __name__ == "__main__":
    main()
