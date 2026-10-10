"""Package the tested folder EXE, rebuildable source, and verified checksums."""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import urllib.request
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

DESKTOP = Path(__file__).resolve().parents[1]
REPO = DESKTOP.parent
DIST = DESKTOP / "dist"


def checksum(path: Path) -> None:
    with path.open("rb") as file:
        digest = hashlib.file_digest(file, "sha256").hexdigest()
    path.with_suffix(path.suffix + ".sha256").write_text(
        f"{digest}  {path.name}\n", encoding="ascii"
    )


def get_source_archives() -> tuple[list[Path], list[dict]]:
    """AGPL/GPL dependencies include their exact, unmodified upstream sources."""
    cache = DESKTOP / ".build" / "upstream-sources"
    cache.mkdir(parents=True, exist_ok=True)
    manifests, archives = [], []
    import importlib.metadata
    for name in ("pdf2zh-next", "babeldoc", "PyMuPDF", "Levenshtein", "python-Levenshtein"):
        version = importlib.metadata.version(name)
        with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json", timeout=60) as response:
            info = json.load(response)
        sdist = next(item for item in info["urls"] if item["packagetype"] == "sdist")
        path = cache / sdist["filename"]
        expected = sdist["digests"]["sha256"]
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            with urllib.request.urlopen(sdist["url"], timeout=120) as response, path.open("wb") as output:
                while data := response.read(1024 * 1024):
                    output.write(data)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Source checksum mismatch: {path.name}")
        archives.append(path)
        manifests.append({"name": name, "version": version, "filename": path.name,
                          "sha256": expected, "url": sdist["url"]})
    # PyMuPDF's sdist does not contain the separately built MuPDF sources.
    # The archive includes MuPDF's bundled third-party source dependencies.
    import pymupdf
    mupdf_version = pymupdf.mupdf_version
    if mupdf_version != "1.25.2":
        raise RuntimeError("Update the verified MuPDF source pin for this runtime version.")
    source = {
        "name": "MuPDF", "version": "1.25.2", "filename": "mupdf-1.25.2-source.tar.gz",
        "sha256": "36ccf6a5e691e188acf8db6e98d08bf05f27bb4ce30432dc15fc76d329a92d4d",
        "url": "https://github.com/ArtifexSoftware/mupdf-downloads/releases/download/1.25.2/mupdf-1.25.2-source.tar.gz",
    }
    path = cache / source["filename"]
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
        with urllib.request.urlopen(source["url"], timeout=120) as response, path.open("wb") as output:
            while data := response.read(1024 * 1024):
                output.write(data)
    if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
        raise RuntimeError("MuPDF source checksum mismatch.")
    archives.append(path)
    manifests.append(source)
    return archives, manifests


def main() -> None:
    app = DIST / "ScanPDF-Desktop"
    if not (app / "ScanPDF-Desktop.exe").is_file():
        raise SystemExit("The tested EXE folder is missing.")
    try:
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO,
                                 capture_output=True, text=True, check=True).stdout.strip()
        dirty = bool(subprocess.run(["git", "status", "--porcelain", "--", "desktop", "scripts/build-windows.ps1",
                                    ".github/workflows/windows.yml", "docs", "README.md"], cwd=REPO,
                                   capture_output=True, text=True, check=True).stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        # The downloadable corresponding-source ZIP deliberately has no .git.
        source_manifest = REPO / "SOURCE_MANIFEST.json"
        revision = (json.loads(source_manifest.read_text(encoding="utf-8")).get("source_revision")
                    if source_manifest.is_file() else "unversioned-source")
        dirty = None  # Local modifications cannot be determined without Git.
    (app / "BUILD.json").write_text(json.dumps({"version": "1.2.0", "source_revision": revision,
        "source_has_local_changes": dirty, "architecture": "Windows x64", "signing": "unsigned"}, indent=2) + "\n", encoding="utf-8")
    for source in (DESKTOP / "LICENSE", DESKTOP / "THIRD_PARTY_NOTICES.md", REPO / "docs" / "windows.md"):
        (app / source.name).write_bytes(source.read_bytes())
    shutil.copytree(DESKTOP / "build" / "licenses", app / "_internal" / "licenses" / "Qt", dirs_exist_ok=True)
    binary_zip = DIST / "ScanPDF-Desktop-Windows-x64.zip"
    with ZipFile(binary_zip, "w", ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(app.rglob("*")):
            if file.is_file():
                archive.write(file, str(file.relative_to(DIST)).replace("\\", "/"))
    checksum(binary_zip)

    upstream, manifests = get_source_archives()
    source_zip = DIST / "ScanPDF-Desktop-Source.zip"
    with ZipFile(source_zip, "w", ZIP_DEFLATED, compresslevel=6) as archive:
        excluded = {".venv", ".build", ".cache", "dist", "__pycache__", ".pytest_cache"}
        for file in sorted(DESKTOP.rglob("*")):
            if file.is_file() and not file.name.startswith(".build-") and not any(part in excluded for part in file.relative_to(DESKTOP).parts):
                archive.write(file, "ScanPDF-Desktop-Source/desktop/" + str(file.relative_to(DESKTOP)).replace("\\", "/"))
        for source in (REPO / "scripts" / "build-windows.ps1", REPO / ".github" / "workflows" / "windows.yml",
                       REPO / "docs" / "windows.md", REPO / "README.md"):
            archive.write(source, "ScanPDF-Desktop-Source/" + str(source.relative_to(REPO)).replace("\\", "/"))
        for file in upstream:
            archive.write(file, "ScanPDF-Desktop-Source/upstream/" + file.name)
        archive.writestr("ScanPDF-Desktop-Source/SOURCE_MANIFEST.json", json.dumps(
            {"source_revision": revision, "upstream": manifests}, indent=2) + "\n")
    checksum(source_zip)
    print(f"Packaged {binary_zip.name} ({binary_zip.stat().st_size // 1024 // 1024} MiB) and corresponding source.")


if __name__ == "__main__":
    main()
