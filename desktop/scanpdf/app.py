"""Desktop entry point; optional headless verification uses the same application."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def configure_fonts(application) -> None:
    from PySide6.QtGui import QFont, QFontDatabase
    # Qt's offscreen platform does not enumerate the Windows font registry.
    # Read system fonts for previews without redistributing Microsoft fonts.
    if application.platformName() == "offscreen" and sys.platform == "win32":
        fonts = Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts"
        for name in ("segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "segoeuiz.ttf"):
            path = fonts / name
            if path.is_file():
                QFontDatabase.addApplicationFont(str(path))
    application.setFont(QFont("Segoe UI", 10))


def main() -> int:
    parser = argparse.ArgumentParser(description="ScanPDF cho Windows")
    parser.add_argument("files", nargs="*")
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--screenshot", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--translation-self-test", type=Path, metavar="INPUT")
    parser.add_argument("--translation-output", type=Path, metavar="DIRECTORY")
    args = parser.parse_args()
    if args.translation_self_test:
        if args.translation_output is None:
            parser.error("--translation-self-test requires --translation-output")
        from .packaging_check import run_translation_check
        return run_translation_check(args.translation_self_test, args.translation_output)
    if args.self_test:
        return self_test()
    if args.screenshot:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtCore import QLockFile, QStandardPaths, QTimer
    from PySide6.QtWidgets import QApplication, QMessageBox
    from .ui import MainWindow

    application = QApplication(sys.argv[:1])
    application.setApplicationName("ScanPDF")
    application.setOrganizationName("duckk37")
    configure_fonts(application)
    root = args.data_dir or Path(QStandardPaths.writableLocation(QStandardPaths.AppLocalDataLocation))
    root.mkdir(parents=True, exist_ok=True)
    lock = QLockFile(str(root / "application.lock"))
    lock.setStaleLockTime(0)
    if not lock.tryLock(100):
        QMessageBox.information(None, "ScanPDF đang mở", "Hãy dùng cửa sổ ScanPDF đang mở để tránh thay đổi thư viện cùng lúc.")
        return 1
    window = MainWindow(root)
    window.show()
    for file in args.files:
        window.import_pdf(Path(file))
    if args.screenshot:
        def capture():
            args.screenshot.parent.mkdir(parents=True, exist_ok=True)
            if not window.grab().save(str(args.screenshot)):
                application.exit(2)
                return
            window.close()
            application.quit()
        QTimer.singleShot(700, capture)
    result = application.exec()
    lock.unlock()
    return result


def self_test() -> int:
    import json
    import tempfile
    import pymupdf
    from .storage import LibraryStore
    from .services import pdf_ops
    from .services.jobs import JobManager, TranslationSettings
    from .services.bridge import BridgeServer

    with tempfile.TemporaryDirectory(prefix="scanpdf-self-test-") as directory:
        root = Path(directory)
        source = root / "fixture.pdf"
        with pymupdf.open() as document:
            page = document.new_page()
            page.insert_text((50, 100), "ScanPDF desktop validation")
            document.save(source)
        store = LibraryStore(root / "library")
        item = store.import_file(source)
        store.toggle_favorite(item)
        assert LibraryStore(root / "library").items[0].favorite
        output = pdf_ops.duplicate(source, root / "duplicated.pdf", [0])
        assert pdf_ops.inspect(output)["page_count"] == 2
        # Importing the engine catches omitted frozen-package dependencies without downloading models.
        import pdf2zh_next.high_level
        import onnxruntime
        import babeldoc
        import keyring
        from .packaging_check import verify_spawned_engine
        verify_spawned_engine()
        manager = JobManager(root / "jobs")
        assert manager.list_jobs() == []
        manager.shutdown()
        print(json.dumps({"status": "passed", "version": "1.2.0", "pdf": "passed", "engine_import": "passed", "engine_spawn": "passed"}))
    return 0
