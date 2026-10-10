"""A local library with atomic writes and backwards-safe metadata."""

from __future__ import annotations

import json
import os
import re
import shutil
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path

import pymupdf


@dataclass
class LibraryItem:
    id: str
    name: str
    filename: str
    created_at: float
    updated_at: float
    page_count: int
    byte_count: int
    favorite: bool = False

    @property
    def size_label(self) -> str:
        if self.byte_count < 1_048_576:
            return f"{self.byte_count / 1024:.0f} KB"
        return f"{self.byte_count / 1_048_576:.1f} MB"


class LibraryStore:
    def __init__(self, root: Path):
        self.root = Path(root).resolve()
        self.files = self.root / "Library"
        self.files.mkdir(parents=True, exist_ok=True)
        self.index = self.root / "library.json"
        self.items: list[LibraryItem] = []
        self.recovery_message = ""
        if self.index.exists():
            try:
                values = json.loads(self.index.read_text(encoding="utf-8"))
                if not isinstance(values, list):
                    raise ValueError("invalid index")
                for value in values:
                    item = LibraryItem(**value)
                    if not re.fullmatch(r"[0-9a-f-]{36}\.pdf", item.filename):
                        raise ValueError("invalid filename")
                    path = self.path(item)
                    # The index is the commit point for deletion. Restore an
                    # interrupted deletion when its original entry survives.
                    backup = path.with_suffix(".deleted")
                    if not path.exists() and backup.is_file():
                        os.replace(backup, path)
                    if path.is_file():
                        self.items.append(item)
            except (ValueError, TypeError, KeyError):
                self.items = []
                shutil.copy2(self.index, self.root / f"library-damaged-{uuid.uuid4()}.json")
                self.recovery_message = "Danh mục bị lỗi. Các PDF đã được khôi phục; hãy đổi lại tên tài liệu."
        known = {item.filename for item in self.items}
        for file in self.files.glob("*.pdf"):
            if file.name in known or not re.fullmatch(r"[0-9a-f-]{36}\.pdf", file.name):
                continue
            try:
                with pymupdf.open(file) as document:
                    count = 0 if document.needs_pass else document.page_count
                self.items.append(LibraryItem(file.stem, "Tài liệu khôi phục", file.name,
                                              file.stat().st_ctime, file.stat().st_mtime,
                                              count, file.stat().st_size))
            except Exception:
                continue
        self._persist(self.items)

    def path(self, item: LibraryItem) -> Path:
        result = (self.files / item.filename).resolve()
        if result.parent != self.files:
            raise ValueError("Đường dẫn tài liệu không hợp lệ.")
        return result

    def import_file(self, source: Path, name: str | None = None) -> LibraryItem:
        source = Path(source)
        with pymupdf.open(source) as document:
            if not document.is_pdf or (not document.needs_pass and not document.page_count):
                raise ValueError("PDF không hợp lệ hoặc không có trang.")
            count = 0 if document.needs_pass else document.page_count
        identifier = str(uuid.uuid4())
        now = time.time()
        item = LibraryItem(identifier, self._name(name if name is not None else source.stem),
                           identifier + ".pdf", now, now, count, source.stat().st_size)
        destination = self.path(item)
        temporary = destination.with_suffix(".pending")
        try:
            shutil.copyfile(source, temporary)
            os.replace(temporary, destination)
            updated = [item, *self.items]
            self._persist(updated)
        except Exception:
            temporary.unlink(missing_ok=True)
            destination.unlink(missing_ok=True)
            raise
        self.items = updated
        return item

    def rename(self, item: LibraryItem, name: str):
        old = item.name
        item.name = self._name(name)
        try:
            self._persist(self.items)
        except Exception:
            item.name = old
            raise

    def toggle_favorite(self, item: LibraryItem):
        item.favorite = not item.favorite
        try:
            self._persist(self.items)
        except Exception:
            item.favorite = not item.favorite
            raise

    def delete(self, item: LibraryItem):
        source = self.path(item)
        backup = source.with_suffix(".deleted")
        os.replace(source, backup)
        updated = [entry for entry in self.items if entry.id != item.id]
        try:
            self._persist(updated)
        except Exception:
            os.replace(backup, source)
            raise
        self.items = updated
        backup.unlink(missing_ok=True)

    def _persist(self, items: list[LibraryItem]):
        temporary = self.index.with_suffix(".pending")
        with temporary.open("w", encoding="utf-8") as stream:
            json.dump([asdict(item) for item in items], stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.index)

    @staticmethod
    def _name(value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Hãy nhập tên tài liệu.")
        return value[:120]
