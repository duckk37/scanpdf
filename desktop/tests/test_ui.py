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


def test_gemini_configuration_consent_and_async_answer_preserve_pdf(application, tmp_path, monkeypatch):
    import keyring
    saved = {}
    monkeypatch.setattr(keyring, "get_password", lambda *args: None)
    monkeypatch.setattr(keyring, "set_password", lambda service, name, key: saved.update({name: key}))
    source = tmp_path / "source.pdf"
    with pymupdf.open() as doc:
        doc.new_page().insert_text((50, 90), "Energy and motion")
        doc.save(source)
    original = source.read_bytes()
    window = MainWindow(tmp_path / "app-data")
    errors, calls = [], []
    monkeypatch.setattr(window, "message", lambda text, error=False: errors.append(text))
    item = window.import_pdf(source)
    window.gemini_key.setText("fake-test-key")
    assert window.save_gemini_settings() is not None
    assert saved["gemini-api-key"] == "fake-test-key"
    assert "fake-test-key" not in window.preferences_file.read_text()
    assert window.manager.default_settings.service == "google"
    window.navigate(4)
    window.assistant_mode.setCurrentIndex(window.assistant_mode.findData("question"))
    window.assistant_question.setPlainText("Năng lượng là gì?")
    def answer(path, mode, question, password):
        calls.append((path, mode, question, password))
        return {"answer": "Năng lượng là khả năng thực hiện công.", "pages": [1], "model": "gemini-3.8-flash", "page_count": 1}
    monkeypatch.setattr(window.assistant, "analyze_pdf", answer)
    window.start_assistant()
    assert not calls and errors  # No upload until the user opts in.
    errors.clear()
    window.assistant_consent.setChecked(True)
    window.start_assistant()
    deadline = time.monotonic() + 10
    while window.assistant_inflight and time.monotonic() < deadline:
        application.processEvents()
        time.sleep(.02)
    assert not window.assistant_inflight and len(calls) == 1 and not errors
    assert "Năng lượng là khả năng" in window.assistant_result.toPlainText()
    assert "đối chiếu: 1" in window.assistant_result.toPlainText()
    assert not window.assistant_consent.isChecked()
    assert source.read_bytes() == original and len(window.store.items) == 1
    assert window.open_item(item.id) and window.stack.currentIndex() == 5
    window.close()


def test_stopping_gemini_wait_discards_late_answer(application, tmp_path, monkeypatch):
    import threading
    import keyring
    monkeypatch.setattr(keyring, "get_password", lambda *args: None)
    monkeypatch.setattr(keyring, "set_password", lambda *args: None)
    source = tmp_path / "source.pdf"
    with pymupdf.open() as doc:
        doc.new_page().insert_text((50, 90), "Energy and motion")
        doc.save(source)
    window = MainWindow(tmp_path / "app-data")
    window.import_pdf(source)
    window.gemini_key.setText("fake-test-key")
    window.save_gemini_settings()
    window.navigate(4)
    started, released = threading.Event(), threading.Event()
    def answer(*args, **kwargs):
        started.set()
        assert released.wait(5)
        return {"answer": "Late answer", "pages": [1], "model": "gemini-3.8-flash"}
    monkeypatch.setattr(window.assistant, "analyze_pdf", answer)
    window.assistant_consent.setChecked(True)
    window.start_assistant()
    assert started.wait(3)
    window.stop_assistant_wait()
    released.set()
    deadline = time.monotonic() + 10
    while window.assistant_inflight and time.monotonic() < deadline:
        application.processEvents()
        time.sleep(.02)
    assert not window.assistant_inflight
    assert "Late answer" not in window.assistant_result.toPlainText()
    assert "Đã ngừng chờ" in window.assistant_result.toPlainText()
    window.close()
