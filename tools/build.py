#!/usr/bin/env python3
"""Build a manager-installable ZIP without the runtime swap image."""
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

root = Path(__file__).resolve().parents[1]
output = root / "dist" / "additional-swap.zip"
output.parent.mkdir(exist_ok=True)
with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
    for path in sorted((root / "module").iterdir()):
        if not path.is_file():
            raise SystemExit(f"Unexpected module entry: {path}")
        info = ZipInfo(path.name, date_time=(2026, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = (0o100755 if path.suffix == ".sh" else 0o100644) << 16
        info.compress_type = ZIP_DEFLATED
        archive.writestr(info, path.read_bytes())
print(output)
