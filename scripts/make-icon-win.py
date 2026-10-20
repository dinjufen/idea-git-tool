"""由 assets/icon/GitDeck-1024.png 生成 Windows 图标与欢迎页标志（需要 Pillow）。

用法：python scripts/make-icon-win.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "icon" / "GitDeck-1024.png"
OUT = ROOT / "apps" / "windows" / "GitDeck" / "Assets"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    image = Image.open(SOURCE).convert("RGBA")
    sizes = [(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)]
    image.save(OUT / "GitDeck.ico", sizes=sizes)
    image.resize((128, 128), Image.LANCZOS).save(OUT / "Logo.png")


if __name__ == "__main__":
    main()
