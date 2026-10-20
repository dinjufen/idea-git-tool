"""向共用文案文件 Localizable.xcstrings 添加或更新条目（保持 Xcode 的格式）。

用法：python scripts/l10n-add.py <键名> <英文> <简体中文> [<键名> <英文> <简体中文> ...]
Windows 专属的说法使用 `<原键名>.win` 作为键名（见 apps/windows/GitDeck/Common/L10n.cs）。
"""
import json
import sys
from pathlib import Path

FILE = Path(__file__).resolve().parent.parent / "apps/mac/Sources/GitDeck/Resources/Localizable.xcstrings"


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def main(args: list[str]) -> None:
    if not args or len(args) % 3:
        sys.exit(__doc__)
    data = json.loads(FILE.read_text(encoding="utf-8"))
    for key, en, zh in zip(args[0::3], args[1::3], args[2::3]):
        data["strings"][key] = {
            "extractionState": "manual",
            "localizations": {"en": unit(en), "zh-Hans": unit(zh)},
        }
    FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main(sys.argv[1:])
