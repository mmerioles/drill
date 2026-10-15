#!/usr/bin/env python3
"""Writes windows/Drill/Assets/drill.ico from docs/icon.png, each size
downscaled from the full art so small ones stay crisp. Needs Pillow:
python3 windows/scripts/make-icon.py"""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[2]  # the repo
art = Image.open(root / "docs/icon.png").convert("RGBA")
sizes = [16, 20, 24, 32, 40, 48, 64, 256]
frames = [art.resize((s, s), Image.Resampling.LANCZOS) for s in sizes]
out = root / "windows/Drill/Assets/drill.ico"
out.parent.mkdir(parents=True, exist_ok=True)
frames[-1].save(out, format="ICO", sizes=[(s, s) for s in sizes], append_images=frames[:-1])
print(out.relative_to(root))
