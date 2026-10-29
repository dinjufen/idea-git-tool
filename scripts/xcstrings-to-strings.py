"""把 Localizable.xcstrings 转换为各语言的 <lang>.lproj/Localizable.strings。

SwiftPM 只有在工具链带有 xcstringstool 时才会编译 .xcstrings；否则资源包里只有原始的 .xcstrings，
运行时查不到文案，界面上显示的全是键名。scripts/build-mac-app.sh 在资源包中没有编译好的 .lproj 时调用本脚本。

用法：python3 scripts/xcstrings-to-strings.py <Localizable.xcstrings> <输出目录（资源包）>
Windows 专属的 `<键名>.win` 条目不写入。
"""
import json
import sys
from pathlib import Path


def escape(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def main(source: str, output: str) -> None:
    data = json.loads(Path(source).read_text(encoding="utf-8"))
    tables: dict[str, list[str]] = {}
    for key, entry in sorted(data.get("strings", {}).items()):
        if key.endswith(".win"):
            continue
        for lang, localization in entry.get("localizations", {}).items():
            unit = localization.get("stringUnit")
            if not unit:
                continue
            tables.setdefault(lang, []).append(f'"{escape(key)}" = "{escape(unit["value"])}";')
    if not tables:
        sys.exit(f"no localizations found in {source}")
    for lang, lines in tables.items():
        folder = Path(output) / f"{lang}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"{folder / 'Localizable.strings'}: {len(lines)} entries")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
