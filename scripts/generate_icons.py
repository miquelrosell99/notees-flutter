#!/usr/bin/env python3
"""Generate Android and iOS launcher icons from the Notees PWA source icon."""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path("frontend/public/pwa-512.png")
ANDROID_RES = ROOT / "android/app/src/main/res"
IOS_ICONSET = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"

# Android legacy launcher sizes
ANDROID_LEGACY = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# Android adaptive foreground sizes (108dp asset)
ANDROID_ADAPTIVE = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# iOS AppIcon sizes from Flutter template
IOS_ICONS: list[tuple[str, int]] = [
    ("Icon-App-20x20@1x.png", 20),
    ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60),
    ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58),
    ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@1x.png", 40),
    ("Icon-App-40x40@2x.png", 80),
    ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-60x60@2x.png", 120),
    ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-76x76@1x.png", 76),
    ("Icon-App-76x76@2x.png", 152),
    ("Icon-App-83.5x83.5@2x.png", 167),
    ("Icon-App-1024x1024@1x.png", 1024),
]

BACKGROUND_COLOR = "#111111"


def _make_transparent_background(img: Image.Image, threshold: int = 40) -> Image.Image:
    """Flood-fill the outer background color with transparency."""
    rgba = img.convert("RGBA")
    # Add a 1px transparent border so floodfill can reach all edge pixels.
    bordered = Image.new("RGBA", (rgba.width + 2, rgba.height + 2), (0, 0, 0, 0))
    bordered.paste(rgba, (1, 1))

    width, height = bordered.size
    seeds = []
    for x in range(width):
        seeds.append((x, 0))
        seeds.append((x, height - 1))
    for y in range(height):
        seeds.append((0, y))
        seeds.append((width - 1, y))

    for seed in seeds:
        try:
            ImageDraw.floodfill(
                bordered,
                seed,
                value=(0, 0, 0, 0),
                thresh=threshold,
            )
        except ValueError:
            # Seed may already be transparent/outside; ignore.
            pass

    # Crop back the 1px border.
    return bordered.crop((1, 1, width - 1, height - 1))


def _scale_to_fit(img: Image.Image, size: int, padding_ratio: float = 0.0) -> Image.Image:
    """Scale image to fit inside a square of `size`, adding optional padding."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fit_size = int(size * (1 - padding_ratio * 2))
    scaled = img.copy()
    scaled.thumbnail((fit_size, fit_size), Image.LANCZOS)
    x = (size - scaled.width) // 2
    y = (size - scaled.height) // 2
    canvas.paste(scaled, (x, y), scaled)
    return canvas


def generate_android_legacy(source: Image.Image) -> None:
    for folder, size in ANDROID_LEGACY.items():
        out_dir = ANDROID_RES / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        icon = source.resize((size, size), Image.LANCZOS)
        icon.save(out_dir / "ic_launcher.png", "PNG")


def generate_android_adaptive(source: Image.Image) -> None:
    foreground = _make_transparent_background(source)
    anydpi_dir = ANDROID_RES / "mipmap-anydpi-v26"
    anydpi_dir.mkdir(parents=True, exist_ok=True)
    (anydpi_dir / "ic_launcher.xml").write_text(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
        "    <background android:drawable=\"@color/ic_launcher_background\" />\n"
        "    <foreground android:drawable=\"@mipmap/ic_launcher_foreground\" />\n"
        "</adaptive-icon>\n"
    )

    colors_dir = ANDROID_RES / "values"
    colors_dir.mkdir(parents=True, exist_ok=True)
    (colors_dir / "colors.xml").write_text(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<resources>\n"
        f"    <color name=\"ic_launcher_background\">{BACKGROUND_COLOR}</color>\n"
        "</resources>\n"
    )

    for folder, size in ANDROID_ADAPTIVE.items():
        out_dir = ANDROID_RES / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        icon = _scale_to_fit(foreground, size, padding_ratio=0.14)
        icon.save(out_dir / "ic_launcher_foreground.png", "PNG")


def generate_ios(source: Image.Image) -> None:
    IOS_ICONSET.mkdir(parents=True, exist_ok=True)
    for filename, size in IOS_ICONS:
        icon = source.resize((size, size), Image.LANCZOS)
        icon.save(IOS_ICONSET / filename, "PNG")
    # Ensure Contents.json references exist. Flutter already provides one, so keep it.


def main() -> int:
    repo_root = ROOT.parent
    source_path = repo_root / SOURCE
    if not source_path.exists():
        print(f"Source icon not found: {source_path}", file=sys.stderr)
        return 1

    source = Image.open(source_path)
    generate_android_legacy(source)
    generate_android_adaptive(source)
    generate_ios(source)
    print("Launcher icons generated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
