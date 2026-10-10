# PyInstaller folder build: keep Qt DLLs replaceable and avoid onefile extraction.
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs
from PyInstaller.utils.hooks import collect_submodules, copy_metadata

desktop_dir = Path(SPECPATH).parent
repo_dir = desktop_dir.parent

datas = []
binaries = []
hiddenimports = [
    "keyring.backends.Windows", "keyring.backends.fail", "keyring.backends.null",
    "PySide6.QtMultimedia", "PySide6.QtMultimediaWidgets",
    "uvicorn.logging", "uvicorn.loops.asyncio", "uvicorn.protocols.http.h11_impl",
    "uvicorn.protocols.websockets.websockets_impl", "uvicorn.lifespan.on",
]

# Config models and translators are selected dynamically and are also pickled
# into BabelDOC's spawned worker. Do not pull upstream's unused Gradio UI.
for package in ("babeldoc", "pdf2zh_next", "rapidocr_onnxruntime", "tiktoken_ext"):
    hiddenimports += collect_submodules(
        package,
        filter=lambda module: module not in ("pdf2zh_next.i18n", "pdf2zh_next.main") and not any(
            part in module.split(".") for part in ("gui", "tests", "test")
        ),
        on_error="warn once",
    )
    datas += collect_data_files(package, include_py_files=False)

for package in ("onnxruntime", "rtree", "freetype", "cv2"):
    binaries += collect_dynamic_libs(package)

for distribution in ("pdf2zh-next", "keyring", "PySide6", "PyInstaller"):
    datas += copy_metadata(distribution, recursive=True)

generated_notices = desktop_dir / ".build" / "licenses"
if generated_notices.exists():
    datas.append((str(generated_notices), "licenses"))
datas += [(str(desktop_dir / "LICENSE"), "."),
          (str(desktop_dir / "THIRD_PARTY_NOTICES.md"), ".")]

a = Analysis(
    [str(desktop_dir / "main.py")],
    pathex=[str(desktop_dir)],
    binaries=binaries,
    datas=datas,
    hiddenimports=sorted(set(hiddenimports)),
    excludes=["gradio", "gradio_client", "gradio_pdf", "gradio_i18n",
              "pytest", "tkinter", "PyQt5", "PyQt6", "PySide2"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, [], exclude_binaries=True,
    name="ScanPDF-Desktop", debug=False, bootloader_ignore_signals=False,
    strip=False, upx=False, console=False,
    version=str(desktop_dir / "build" / "version-info.txt"),
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False,
               name="ScanPDF-Desktop")
