"""Copy installed distribution notices and exact source locations into the build."""
from __future__ import annotations

import argparse
import importlib.metadata
import json
import re
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    inventory = []
    for dist in sorted(importlib.metadata.distributions(), key=lambda d: d.metadata["Name"].lower()):
        name = dist.metadata["Name"]
        folder = args.output / re.sub(r"[^a-zA-Z0-9_.-]", "_", name)
        copied = []
        for path in dist.files or []:
            if any(word in path.name.lower() for word in ("license", "licence", "copying", "notice")):
                source = Path(dist.locate_file(path))
                if source.is_file() and source.suffix.lower() not in (".py", ".pyc", ".pyd", ".dll"):
                    # Preserve paths so multiple bundled native-library notices survive.
                    target = folder / str(path).replace("..", "_")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.read_bytes())
                    copied.append(str(target.relative_to(args.output)).replace("\\", "/"))
        inventory.append({
            "name": name, "version": dist.version,
            "license": dist.metadata.get("License-Expression") or dist.metadata.get("License", ""),
            "project_urls": dist.metadata.get_all("Project-URL") or [],
            "source_metadata": f"https://pypi.org/pypi/{name}/{dist.version}/json",
            "license_files": copied,
        })
    (args.output / "DEPENDENCIES.json").write_text(
        json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if python_license.is_file():
        (args.output / "Python-LICENSE.txt").write_bytes(python_license.read_bytes())
    print(f"Collected notices for {len(inventory)} installed distributions.")


if __name__ == "__main__":
    main()
