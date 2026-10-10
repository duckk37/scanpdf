from pathlib import Path

import pymupdf
import pytest

from scanpdf.storage import LibraryStore


def sample(path: Path):
    with pymupdf.open() as document:
        page = document.new_page()
        page.insert_text((50, 100), "Library persistence test")
        document.save(path)
    return path


def test_library_reload_favorite_rename_and_delete_keep_original(tmp_path):
    source = sample(tmp_path / "source.pdf")
    original = source.read_bytes()
    store = LibraryStore(tmp_path / "library")
    item = store.import_file(source, "Tài liệu tiếng Việt")
    store.toggle_favorite(item)
    store.rename(item, "  Hóa đơn tháng 10  ")
    reopened = LibraryStore(tmp_path / "library")
    assert reopened.items[0].favorite
    assert reopened.items[0].name == "Hóa đơn tháng 10"
    assert reopened.items[0].page_count == 1
    assert reopened.path(reopened.items[0]).read_bytes() == original
    reopened.delete(reopened.items[0])
    assert not LibraryStore(tmp_path / "library").items
    assert source.read_bytes() == original


def test_corrupt_metadata_recovers_pdf_without_overwriting_original_index_backup(tmp_path):
    source = sample(tmp_path / "source.pdf")
    store = LibraryStore(tmp_path / "library")
    item = store.import_file(source)
    store.index.write_text("invalid JSON", encoding="utf-8")
    recovered = LibraryStore(store.root)
    assert recovered.items[0].id == item.id
    assert recovered.recovery_message
    assert next(store.root.glob("library-damaged-*.json")).read_text() == "invalid JSON"


def test_failed_metadata_updates_roll_back_delete_favorite_and_rename(tmp_path, monkeypatch):
    store = LibraryStore(tmp_path / "library")
    item = store.import_file(sample(tmp_path / "source.pdf"))
    original = store.path(item).read_bytes()
    def unavailable(_):
        raise OSError("disk unavailable")
    monkeypatch.setattr(store, "_persist", unavailable)
    with pytest.raises(OSError):
        store.delete(item)
    assert store.path(item).read_bytes() == original
    with pytest.raises(OSError):
        store.toggle_favorite(item)
    assert not item.favorite
    with pytest.raises(OSError):
        store.rename(item, "New name")
    assert item.name == "source"


def test_rejects_invalid_pdf(tmp_path):
    source = tmp_path / "invalid.pdf"
    source.write_bytes(b"not a pdf")
    store = LibraryStore(tmp_path / "library")
    with pytest.raises(Exception):
        store.import_file(source)
    assert not store.items
    assert not list(store.files.glob("*.pdf"))


def test_interrupted_delete_restores_file_and_original_metadata(tmp_path):
    store = LibraryStore(tmp_path / "library")
    item = store.import_file(sample(tmp_path / "source.pdf"), "Named original")
    store.toggle_favorite(item)
    store.path(item).rename(store.path(item).with_suffix(".deleted"))
    reopened = LibraryStore(store.root)
    assert reopened.items[0].name == "Named original"
    assert reopened.items[0].favorite
    assert reopened.path(reopened.items[0]).is_file()


def test_unsafe_metadata_cannot_import_pdf_outside_library(tmp_path):
    import json
    from dataclasses import asdict
    source = sample(tmp_path / "source.pdf")
    store = LibraryStore(tmp_path / "library")
    item = store.import_file(source)
    metadata = asdict(item)
    metadata["filename"] = "../../source.pdf"
    store.index.write_text(json.dumps([metadata]), encoding="utf-8")
    recovered = LibraryStore(store.root)
    assert len(recovered.items) == 1
    assert recovered.path(recovered.items[0]).parent == store.files
    assert source.exists()
