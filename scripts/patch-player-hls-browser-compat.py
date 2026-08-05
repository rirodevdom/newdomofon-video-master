#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def patch_player_kit(path: Path) -> None:
    text = path.read_text(encoding="utf-8")

    old = 'if(this.video.canPlayType("application/vnd.apple.mpegurl"))return this.video.src=e,t;if(!_e.isSupported())throw new Error("HLS is not supported by this browser");const i=new _e({' 
    new = 'if(!_e.isSupported()){if(this.video.canPlayType("application/vnd.apple.mpegurl"))return this.video.src=e,t;throw new Error("HLS is not supported by this browser")}this.video.removeAttribute("src"),this.video.load();const i=new _e({' 

    if new in text:
        print("Player-kit already prefers hls.js/MSE over partial native HLS support")
        return

    count = text.count(old)
    if count != 1:
        raise SystemExit(f"player-kit HLS engine selection: expected one source block, found {count}")

    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Player-kit now prefers hls.js/MSE and keeps native HLS as fallback")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_player_kit(root / "frontend/public/player-kit/newdomofon-player.iife.js")


if __name__ == "__main__":
    main()
