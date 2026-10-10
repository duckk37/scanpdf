import os
import time

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pymupdf
import pytest
from PySide6.QtWidgets import QApplication

from scanpdf.ui import MainWindow


@pytest.fixture(scope="module")
def application():
    return QApplication.instance() or QApplication([])


def test_native_window_opens_pdf_and_async_tool_saves_copy(application, tmp_path, monkeypatch):
    import keyring
    monkeypatch.setattr(keyring, "get_password", lambda *args: None)
    monkeypatch.setattr(keyring, "set_password", lambda *args: None)
    source = tmp_path / "source.pdf"
    with pymupdf.open() as document:
        page = document.new_page()
        page.insert_text((50, 100), "Page body")
        document.save(source)
    window = MainWindow(tmp_path / "app-data")
    errors = []
    monkeypatch.setattr(window, "message", lambda text, error=False: errors.append(text))
    item = window.import_pdf(source)
    assert window.open_item(item.id)
    assert not window.preview.pixmap().isNull()
    window.document_tool("duplicate")
    deadline = time.monotonic() + 10
    while window.busy and time.monotonic() < deadline:
        application.processEvents()
        time.sleep(.02)
    application.processEvents()
    assert not window.busy
    assert not errors
    assert len(window.store.items) == 2
    assert window.current.page_count == 2
    with pymupdf.open(source) as original:
        assert original.page_count == 1
    window.close()
    assert window.manager._closed


def test_page_ranges_reject_duplicates_and_out_of_bounds(application, tmp_path, monkeypatch):
    import keyring
    monkeypatch.setattr(keyring, "get_password", lambda *args: None)
    monkeypatch.setattr(keyring, "set_password", lambda *args: None)
    window = MainWindow(tmp_path / "app-data")
    window.page_spec.setText("1-3,5")
    assert window.pages_from_input(5) == [0, 1, 2, 4]
    for text in ("0", "2-1", "1,1", "6", "1-999999"):
        window.page_spec.setText(text)
        with pytest.raises(ValueError):
            window.pages_from_input(5)
    window.close()
