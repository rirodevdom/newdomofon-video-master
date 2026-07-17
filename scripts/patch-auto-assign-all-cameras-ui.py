#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_required(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1), True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    path = Path(args.project_dir).resolve() / "frontend/src/views/AdminView.vue"
    if not path.is_file():
        raise SystemExit(f"Admin view is missing: {path}")

    text = path.read_text(encoding="utf-8")
    changed = False

    replacements = (
        (
            'label="Автоматически назначать новым камерам"',
            'label="Автоматически назначать всем камерам"',
            "auto-assignment label",
        ),
        (
            'hint="Токен будет добавляться к каждой новой камере. Существующие камеры не меняются."',
            'hint="Токен сразу назначается всем существующим камерам и будет автоматически добавляться к новым."',
            "auto-assignment hint",
        ),
        (
            '<th>Авто новым камерам</th>',
            '<th>Авто всем камерам</th>',
            "auto-assignment table header",
        ),
        (
            "? 'Токен будет автоматически назначаться новым камерам'",
            "? 'Токен назначен всем существующим камерам и будет назначаться новым'",
            "auto-assignment enabled notification",
        ),
        (
            ": 'Автопривязка токена к новым камерам отключена');",
            ": 'Автопривязка токена отключена; существующие назначения сохранены');",
            "auto-assignment disabled notification",
        ),
    )

    for old, new, label in replacements:
        text, did_change = replace_required(text, old, new, label)
        changed |= did_change

    required = (
        "Автоматически назначать всем камерам",
        "всем существующим камерам",
        "Авто всем камерам",
        "существующие назначения сохранены",
    )
    missing = [marker for marker in required if marker not in text]
    if missing:
        raise RuntimeError(f"all-camera auto-assignment UI markers missing: {missing}")

    if changed:
        path.write_text(text, encoding="utf-8")
        print(f"All-camera auto-assignment UI updated: {path}")
    else:
        print(f"All-camera auto-assignment UI already up to date: {path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
