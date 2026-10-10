"""Create Windows/Python 3.12 hash locks from a pip --ignore-installed report.

Resolve requirements-build.in in a clean venv, then run:
python -m pip install --dry-run --ignore-installed --report .build/lock-report.json -r requirements-build.in
python build/lock_requirements.py .build/lock-report.json
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name


def main() -> None:
    report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    packages = {canonicalize_name(row["metadata"]["name"]): row for row in report["install"]}
    desktop = Path(__file__).resolve().parents[1]
    runtime_roots = [Requirement(line) for line in (desktop / "requirements.in").read_text().splitlines()
                     if line.strip() and not line.startswith("#")]
    wanted: dict[str, set[str]] = {}
    queue = runtime_roots[:]
    while queue:
        requirement = queue.pop()
        name = canonicalize_name(requirement.name)
        extras = set(requirement.extras)
        if name in wanted and extras <= wanted[name]:
            continue
        wanted.setdefault(name, set()).update(extras)
        for raw in packages[name]["metadata"].get("requires_dist", []):
            child = Requirement(raw)
            if not child.marker or any(child.marker.evaluate({"extra": extra}) for extra in wanted[name] | {""}):
                queue.append(child)
    header = "# Windows x64 / CPython 3.12 only. Generated from requirements-build.in.\n# Exact wheel hashes verified by pip; regenerate with desktop/build/lock_requirements.py.\n"
    def lines(names: set[str]) -> str:
        output = []
        for name in sorted(names):
            row = packages[name]
            digest = row["download_info"]["archive_info"]["hashes"]["sha256"]
            output.append(f"{row['metadata']['name']}=={row['metadata']['version']} --hash=sha256:{digest}")
        return "\n".join(output) + "\n"
    (desktop / "requirements.txt").write_text(header + lines(set(wanted)), encoding="utf-8")
    (desktop / "requirements-build.txt").write_text(
        header + "-r requirements.txt\n" + lines(set(packages) - set(wanted)), encoding="utf-8"
    )
    print(f"Locked {len(wanted)} runtime and {len(packages) - len(wanted)} build distributions.")


if __name__ == "__main__":
    main()
