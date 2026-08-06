#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "newdomofon-hikvision-smartyard-upstream-auth-v1"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1)


def patch_resolver(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return False
    if "newdomofon-hikvision-smartyard-links-v1" not in text:
        raise RuntimeError("Hikvision SmartYard links must be materialized before upstream auth")

    text = replace_once(
        text,
        """  node_public_url: string | null;
  node_media_secret: string;
};""",
        """  node_public_url: string | null;
  node_media_secret: string;
  node_agent_token_hash: string | null;
};""",
        "Hikvision SmartYard agent hash type",
    )

    anchor = """function sendHikvisionResolved(
  res: any,
  channel: HikvisionSmartYardRow,"""
    helper = """// newdomofon-hikvision-smartyard-upstream-auth-v1
function hikvisionSmartYardUpstreamSecret(channel: HikvisionSmartYardRow): string {
  // Match the already proven master Hikvision player: the Hikvision-node can
  // validate a media token signed with SHA-256(DVR_NODE_TOKEN), and master
  // persists that value as agent_token_hash. Keep media_secret as a fallback
  // for older node registrations.
  const agentHash = String(channel.node_agent_token_hash || '').trim();
  if (/^[a-f0-9]{64}$/i.test(agentHash)) return agentHash;
  return String(channel.node_media_secret || '').trim();
}

function sendHikvisionResolved(
  res: any,
  channel: HikvisionSmartYardRow,"""
    text = replace_once(text, anchor, helper, "Hikvision SmartYard upstream secret helper")

    text = replace_once(
        text,
        """  const upstreamToken = signUpstreamToken(channel.node_media_secret, {
    channel_id: channel.channel_external_id,""",
        """  const upstreamSecret = hikvisionSmartYardUpstreamSecret(channel);
  if (!upstreamSecret) return res.status(409).json({ error: 'Hikvision upstream media credential is not configured' });
  const upstreamToken = signUpstreamToken(upstreamSecret, {
    channel_id: channel.channel_external_id,""",
        "Hikvision SmartYard upstream token secret",
    )

    text = replace_once(
        text,
        """              ds.public_base_url AS node_public_url,
              ds.media_secret AS node_media_secret
         FROM hikvision_node_channels h""",
        """              ds.public_base_url AS node_public_url,
              ds.media_secret AS node_media_secret,
              ds.agent_token_hash AS node_agent_token_hash
         FROM hikvision_node_channels h""",
        "Hikvision SmartYard agent hash query",
    )

    for required in (
        MARKER,
        "hikvisionSmartYardUpstreamSecret(channel)",
        "ds.agent_token_hash AS node_agent_token_hash",
        "const upstreamToken = signUpstreamToken(upstreamSecret",
    ):
        if required not in text:
            raise RuntimeError(f"Hikvision SmartYard upstream auth marker missing: {required}")

    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()
    project = Path(args.project_dir).resolve()
    target = project / "backend/src/routes/internalSmartYard.ts"
    if not target.is_file():
        raise SystemExit(f"Target not found: {target}")
    changed = patch_resolver(target)
    print("Hikvision SmartYard upstream authentication prepared")
    print("  changed: backend/src/routes/internalSmartYard.ts" if changed else "  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
