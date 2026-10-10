from __future__ import annotations

import json
import shutil
import socket
import tempfile
import uuid
from datetime import datetime
from pathlib import Path

import pymupdf
from PySide6.QtCore import QObject, QRunnable, QThreadPool, QTimer, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QImage, QPixmap
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QFrame, QGridLayout, QHBoxLayout, QInputDialog, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QMainWindow, QMessageBox, QProgressBar, QPushButton, QScrollArea,
    QSpinBox, QSplitter, QStackedWidget, QTextEdit, QVBoxLayout, QWidget,
)

from . import __version__
from .storage import LibraryItem, LibraryStore
from .services import pdf_ops
from .services.jobs import JobManager, TranslationSettings
from .services.bridge import BridgeServer


STYLE = """
QMainWindow, QDialog { background: #f3f6f8; }
QWidget { color: #173744; font-family: 'Segoe UI'; font-size: 14px; }
QFrame#Sidebar { background: #153440; border-radius: 0px; }
QFrame#Sidebar QLabel { color: #e9f4f2; }
QFrame#Sidebar QPushButton { background: transparent; color: #c8dadd; text-align: left; border: 0; padding: 14px 18px; }
QFrame#Sidebar QPushButton:checked { background: #25515b; color: white; border-left: 3px solid #34c5aa; }
QLabel#Brand { color: white; font-size: 27px; font-weight: 700; }
QLabel#Title { font-size: 28px; font-weight: 700; }
QLabel#Subheading { font-size: 18px; font-weight: 600; }
QLabel#Muted { color: #667d86; }
QFrame#Card { background: white; border: 1px solid #e0e8ed; border-radius: 14px; }
QFrame#Banner { background: #087f79; border-radius: 18px; }
QFrame#Banner QLabel { color: white; }
QPushButton { background: white; border: 1px solid #d4e0e4; border-radius: 8px; padding: 10px 16px; font-weight: 600; }
QPushButton:hover { background: #eaf4f3; border-color: #80b8b4; }
QPushButton:disabled { color: #98aab0; background: #eef2f4; border-color: #e1e8eb; }
QPushButton#Primary { color: white; background: #087f79; border-color: #087f79; }
QPushButton#Primary:hover { background: #086d68; }
QPushButton#Danger { color: #b34a4a; }
QLineEdit, QComboBox, QSpinBox, QTextEdit { background: white; border: 1px solid #d4e0e4; border-radius: 7px; padding: 8px; }
QLineEdit:focus, QTextEdit:focus { border-color: #087f79; }
QListWidget { background: white; border: 1px solid #dfe8ec; border-radius: 12px; padding: 7px; }
QListWidget::item { padding: 15px; border-bottom: 1px solid #edf2f4; }
QListWidget::item:selected { background: #dcefeb; color: #173744; border-radius: 8px; }
QScrollArea { background: transparent; border: 0; }
QProgressBar { border: 1px solid #d4e0e4; border-radius: 6px; background: #e7eff0; text-align: center; min-height: 18px; }
QProgressBar::chunk { background: #087f79; border-radius: 5px; }
QSplitter::handle { background: #e1e9ed; }
"""


def label(text: str, style: str | None = None) -> QLabel:
    result = QLabel(text)
    result.setTextFormat(Qt.PlainText)
    result.setWordWrap(True)
    if style:
        result.setObjectName(style)
    return result


def button(text: str, action, primary=False) -> QPushButton:
    result = QPushButton(text)
    if primary:
        result.setObjectName("Primary")
    result.clicked.connect(action)
    return result


def card() -> tuple[QFrame, QVBoxLayout]:
    frame = QFrame()
    frame.setObjectName("Card")
    layout = QVBoxLayout(frame)
    layout.setContentsMargins(22, 20, 22, 20)
    layout.setSpacing(12)
    return frame, layout


class WorkerSignals(QObject):
    finished = Signal(object)
    failed = Signal(str)


class Worker(QRunnable):
    def __init__(self, operation):
        super().__init__()
        self.operation = operation
        self.signals = WorkerSignals()

    def run(self):
        try:
            self.signals.finished.emit(self.operation())
        except Exception as error:
            self.signals.failed.emit(str(error))


class MainWindow(QMainWindow):
    def __init__(self, root: Path):
        super().__init__()
        self.root = root
        self.store = LibraryStore(root)
        self.manager = JobManager(root / "TranslationJobs")
        self.bridge = None
        self.thread_pool = QThreadPool(self)
        self.thread_pool.setMaxThreadCount(2)
        self.current: LibraryItem | None = None
        self.current_page = 0
        self.passwords: dict[str, str] = {}
        self.workers: set[Worker] = set()
        self.active_job: str | None = None
        self.imported_jobs: set[str] = set()
        self.busy = False
        self.preferences_file = root / "settings.json"
        self.preferences = self._read_preferences()
        self.setWindowTitle(f"ScanPDF {__version__} • Công cụ PDF & dịch tiếng Việt")
        self.resize(1280, 880)
        self.setMinimumSize(1000, 730)
        self.setStyleSheet(STYLE)
        body = QWidget()
        self.setCentralWidget(body)
        row = QHBoxLayout(body)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(0)
        sidebar = QFrame()
        sidebar.setObjectName("Sidebar")
        sidebar.setFixedWidth(210)
        navigation = QVBoxLayout(sidebar)
        navigation.setContentsMargins(16, 28, 16, 22)
        navigation.setSpacing(10)
        navigation.addWidget(label("ScanPDF", "Brand"))
        navigation.addWidget(label("Từ giấy thành tri thức."))
        navigation.addSpacing(28)
        self.navigation_buttons = []
        for title, index in [("Thư viện", 0), ("Công cụ PDF", 1), ("Dịch tiếng Việt", 2), ("Kết nối iPhone", 3)]:
            entry = button(title, lambda checked=False, value=index: self.navigate(value))
            entry.setCheckable(True)
            navigation.addWidget(entry)
            self.navigation_buttons.append(entry)
        navigation.addStretch()
        navigation.addWidget(label(f"Windows • {__version__}"))
        navigation.addWidget(label("PDF trên thiết bị.\nDịch qua nhà cung cấp bạn chọn."))
        row.addWidget(sidebar)
        self.stack = QStackedWidget()
        row.addWidget(self.stack, 1)
        self.stack.addWidget(self.build_library())
        self.stack.addWidget(self.build_tools())
        self.stack.addWidget(self.build_translation())
        self.stack.addWidget(self.build_connection())
        self.stack.addWidget(self.build_document())
        self.statusBar().showMessage("Sẵn sàng. Tài liệu gốc được giữ trong thư viện.")
        self.refresh_library()
        self.navigate(0)
        self.apply_provider_settings(silent=True)
        self.job_timer = QTimer(self)
        self.job_timer.timeout.connect(self.poll_job)
        self.job_timer.start(900)
        if self.store.recovery_message:
            QTimer.singleShot(100, lambda: self.message(self.store.recovery_message))

    def page(self, title: str, subtitle: str) -> tuple[QWidget, QVBoxLayout]:
        widget = QWidget()
        layout = QVBoxLayout(widget)
        layout.setContentsMargins(30, 28, 30, 24)
        layout.setSpacing(18)
        layout.addWidget(label(title, "Title"))
        layout.addWidget(label(subtitle, "Muted"))
        return widget, layout

    def navigate(self, index: int):
        self.stack.setCurrentIndex(index)
        for position, entry in enumerate(self.navigation_buttons):
            entry.setChecked(position == index)
        if index == 2:
            self.refresh_translation_documents()

    def build_library(self):
        page, layout = self.page("Tài liệu của bạn", "Quét, chỉnh sửa và dịch PDF. Mọi bản gốc nằm trong thư viện trên PC.")
        banner = QFrame()
        banner.setObjectName("Banner")
        banner_layout = QHBoxLayout(banner)
        banner_layout.setContentsMargins(26, 25, 26, 25)
        copy = QVBoxLayout()
        copy.addWidget(label("Một nơi cho mọi PDF.", "Subheading"))
        copy.addWidget(label("Giữ tài liệu gọn gàng. Đọc nội dung bằng tiếng Việt."))
        banner_layout.addLayout(copy, 1)
        banner_layout.addWidget(button("Nhập PDF", self.pick_pdfs))
        banner_layout.addWidget(button("Ảnh / Camera → PDF", self.scan_dialog))
        layout.addWidget(banner)
        filters = QHBoxLayout()
        self.search = QLineEdit()
        self.search.setPlaceholderText("Tìm theo tên tài liệu…")
        self.search.textChanged.connect(self.refresh_library)
        self.favorite_filter = QCheckBox("Yêu thích")
        self.favorite_filter.toggled.connect(self.refresh_library)
        self.sort = QComboBox()
        self.sort.addItems(["Mới nhập nhất", "Tên A–Z", "Dung lượng lớn nhất"])
        self.sort.currentIndexChanged.connect(self.refresh_library)
        filters.addWidget(self.search, 1)
        filters.addWidget(self.favorite_filter)
        filters.addWidget(self.sort)
        layout.addLayout(filters)
        self.library_list = QListWidget()
        self.library_list.setSelectionMode(QListWidget.ExtendedSelection)
        self.library_list.itemDoubleClicked.connect(lambda entry: self.open_item(entry.data(Qt.UserRole)))
        layout.addWidget(self.library_list, 1)
        self.library_count = label("", "Muted")
        layout.addWidget(self.library_count)
        actions = QHBoxLayout()
        for title, callback in [("Mở tài liệu", self.open_selected), ("Yêu thích", self.favorite_selected),
                                ("Đổi tên", self.rename_selected), ("Ghép các PDF đã chọn", self.merge_selected),
                                ("Lưu bản sao", self.export_selected), ("Xóa", self.delete_selected)]:
            actions.addWidget(button(title, callback))
        layout.addLayout(actions)
        return page

    def refresh_library(self, *_):
        selected = {entry.data(Qt.UserRole) for entry in self.library_list.selectedItems()}
        self.library_list.clear()
        query = self.search.text().strip().casefold()
        values = [item for item in self.store.items if query in item.name.casefold()
                  and (not self.favorite_filter.isChecked() or item.favorite)]
        mode = self.sort.currentIndex()
        values.sort(key=lambda item: item.name.casefold() if mode == 1 else (-item.byte_count if mode == 2 else -item.created_at))
        for item in values:
            count = f"{item.page_count} trang" if item.page_count else "PDF bảo vệ"
            stamp = datetime.fromtimestamp(item.created_at).strftime("%d/%m/%Y")
            entry = QListWidgetItem(f"{'★  ' if item.favorite else ''}{item.name}\n{count}   ·   {item.size_label}   ·   {stamp}")
            entry.setData(Qt.UserRole, item.id)
            self.library_list.addItem(entry)
            entry.setSelected(item.id in selected)
        self.library_count.setText(f"{len(values)} / {len(self.store.items)} tài liệu  ·  Nhấp đôi để mở; Ctrl + nhấp để chọn nhiều PDF.")

    def selected_items(self):
        identifiers = {entry.data(Qt.UserRole) for entry in self.library_list.selectedItems()}
        return [item for item in self.store.items if item.id in identifiers]

    def single_selected(self):
        items = self.selected_items()
        if len(items) != 1:
            self.message("Hãy chọn một tài liệu trong thư viện.")
            return None
        return items[0]

    def pick_pdfs(self):
        paths, _ = QFileDialog.getOpenFileNames(self, "Nhập PDF", "", "Tài liệu PDF (*.pdf)")
        for path in paths:
            self.import_pdf(Path(path))

    def import_pdf(self, path: Path, name=None):
        try:
            item = self.store.import_file(path, name)
            self.refresh_library()
            self.statusBar().showMessage(f"Đã nhập {item.name}", 6000)
            return item
        except Exception as error:
            self.message(str(error), error=True)
            return None

    def open_selected(self):
        item = self.single_selected()
        if item:
            self.open_item(item.id)

    def favorite_selected(self):
        try:
            for item in self.selected_items():
                self.store.toggle_favorite(item)
            self.refresh_library()
        except Exception as error:
            self.message(str(error), error=True)

    def rename_selected(self):
        item = self.single_selected()
        if item:
            text, accepted = QInputDialog.getText(self, "Đổi tên", "Tên tài liệu", text=item.name)
            if accepted:
                try:
                    self.store.rename(item, text)
                    self.refresh_library()
                except Exception as error:
                    self.message(str(error), error=True)

    def delete_selected(self):
        items = self.selected_items()
        if not items or QMessageBox.question(self, "Xóa tài liệu", f"Xóa {len(items)} tài liệu khỏi thư viện?") != QMessageBox.Yes:
            return
        try:
            for item in items:
                self.store.delete(item)
                self.passwords.pop(item.id, None)
            self.refresh_library()
        except Exception as error:
            self.message(str(error), error=True)

    def export_selected(self):
        item = self.single_selected()
        if item:
            self.save_copy(self.store.path(item), item.name + ".pdf")

    def save_copy(self, source: Path, proposed: str):
        path, _ = QFileDialog.getSaveFileName(self, "Lưu bản sao", proposed.replace("/", "-").replace("\\", "-"), "PDF (*.pdf)")
        if path:
            destination = Path(path)
            if not destination.suffix:
                destination = destination.with_suffix(".pdf")
            if destination.resolve() == source.resolve():
                self.message("Chọn vị trí ngoài thư viện để lưu bản sao.")
                return
            try:
                shutil.copyfile(source, destination)
                self.statusBar().showMessage(f"Đã lưu {destination.name}", 8000)
            except Exception as error:
                self.message(str(error), error=True)

    def message(self, text: str, error=False):
        if error:
            QMessageBox.warning(self, "Không thể hoàn tất", text)
        else:
            QMessageBox.information(self, "ScanPDF", text)

    def run(self, title: str, operation, completed, failed=None):
        if self.busy:
            return
        self.busy = True
        self.statusBar().showMessage(title)
        self.centralWidget().setEnabled(False)
        worker = Worker(operation)
        self.workers.add(worker)

        def finish(value):
            self.workers.discard(worker)
            self.busy = False
            self.centralWidget().setEnabled(True)
            self.statusBar().showMessage("Hoàn tất", 6000)
            completed(value)

        def fail(text):
            self.workers.discard(worker)
            self.busy = False
            self.centralWidget().setEnabled(True)
            if failed:
                failed()
            self.message(text, error=True)

        worker.signals.finished.connect(finish)
        worker.signals.failed.connect(fail)
        self.thread_pool.start(worker)

    def _read_preferences(self):
        try:
            value = json.loads(self.preferences_file.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def build_tools(self):
        page, layout = self.page("Công cụ PDF", "Chọn tài liệu rồi xử lý trên thiết bị. Mỗi thao tác lưu thành bản sao mới.")
        grid = QGridLayout()
        grid.setSpacing(16)
        tools = [
            ("Dịch tiếng Việt", "Giữ bố cục, hình và công thức", "translate"),
            ("Ảnh / Camera → PDF", "Tạo tài liệu từ ảnh chụp", "scan"),
            ("Ghép PDF", "Kết hợp các tài liệu đã chọn", "merge"),
            ("Tách trang", "Trích trang thành PDF mới", "extract"),
            ("Xoay trang", "Chỉnh hướng các trang", "rotate"),
            ("Sắp xếp trang", "Đổi thứ tự của toàn bộ trang", "reorder"),
            ("Chèn PDF", "Thêm các trang từ PDF khác", "insert"),
            ("Nhân bản trang", "Thêm bản sao sau trang gốc", "duplicate"),
            ("Xóa trang", "Bỏ các trang không cần", "delete"),
            ("PDF → ảnh", "Xuất PNG hoặc JPEG", "images"),
            ("Đánh số trang", "Chọn số bắt đầu và vị trí", "number"),
            ("Nén PDF", "Tạo bản nhẹ hơn để chia sẻ", "compress"),
            ("Watermark", "Thêm chữ trên tài liệu", "watermark"),
            ("Đặt mật khẩu", "Bảo vệ một bản sao PDF", "protect"),
            ("Gỡ mật khẩu", "Cần biết mật khẩu hiện tại", "unlock"),
        ]
        for position, (title, subtitle, operation) in enumerate(tools):
            frame, inner = card()
            inner.addWidget(label(title, "Subheading"))
            inner.addWidget(label(subtitle, "Muted"))
            inner.addWidget(button("Sử dụng", lambda checked=False, value=operation: self.choose_tool(value)))
            grid.addWidget(frame, position // 3, position % 3)
        holder = QWidget()
        holder.setLayout(grid)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(holder)
        layout.addWidget(scroll, 1)
        return page

    def choose_tool(self, operation):
        if operation == "scan":
            self.scan_dialog()
            return
        if operation == "merge":
            self.navigate(0)
            self.message("Chọn ít nhất hai PDF trong thư viện, rồi nhấn Ghép các PDF đã chọn.")
            return
        if operation == "translate":
            self.navigate(2)
            return
        choices = [item.name for item in self.store.items]
        if not choices:
            self.navigate(0)
            self.message("Nhập một PDF trước khi dùng công cụ này.")
            return
        text, accepted = QInputDialog.getItem(self, "Chọn tài liệu", "PDF cần xử lý", choices, 0, False)
        if accepted:
            item = self.store.items[choices.index(text)]
            if self.open_item(item.id):
                self.document_tool(operation)

    def build_document(self):
        page, layout = self.page("Xem tài liệu", "Chọn trang và sử dụng các công cụ bên cạnh. Bản gốc luôn được giữ.")
        header = QHBoxLayout()
        header.addWidget(button("← Thư viện", lambda: self.navigate(0)))
        self.document_name = label("", "Subheading")
        header.addWidget(self.document_name, 1)
        header.addWidget(button("Mở bằng app PDF", self.open_external))
        header.addWidget(button("Lưu bản sao", lambda: self.save_copy(self.store.path(self.current), self.current.name + ".pdf") if self.current else None))
        layout.addLayout(header)
        split = QSplitter()
        preview_holder = QWidget()
        preview_layout = QVBoxLayout(preview_holder)
        preview_layout.setContentsMargins(0, 0, 8, 0)
        self.preview = QLabel()
        self.preview.setAlignment(Qt.AlignCenter)
        self.preview.setStyleSheet("background: #dfe8ec; padding: 15px;")
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(self.preview)
        preview_layout.addWidget(scroll, 1)
        controls = QHBoxLayout()
        controls.addWidget(button("← Trang trước", lambda: self.change_page(-1)))
        self.page_counter = label("", "Muted")
        self.page_counter.setAlignment(Qt.AlignCenter)
        controls.addWidget(self.page_counter, 1)
        controls.addWidget(button("Trang sau →", lambda: self.change_page(1)))
        preview_layout.addLayout(controls)
        split.addWidget(preview_holder)
        actions = QWidget()
        actions.setMaximumWidth(285)
        actions_layout = QVBoxLayout(actions)
        self.page_spec = QLineEdit()
        self.page_spec.setPlaceholderText("Ví dụ: 1-3,5")
        actions_layout.addWidget(label("Trang cần xử lý", "Subheading"))
        actions_layout.addWidget(self.page_spec)
        actions_layout.addWidget(label("Để trống: trang đang xem. Sắp xếp yêu cầu đủ tất cả các trang.", "Muted"))
        for title, operation in [("Dịch tiếng Việt", "translate"), ("Tách trang", "extract"), ("Xoay 90°", "rotate"),
                                 ("Nhân bản", "duplicate"), ("Chèn PDF", "insert"), ("Sắp xếp", "reorder"),
                                 ("Xóa trang", "delete"), ("Xuất ảnh", "images"), ("Đánh số", "number"),
                                 ("Nén PDF", "compress"), ("Watermark", "watermark"),
                                 ("Đặt mật khẩu", "protect"), ("Gỡ mật khẩu", "unlock")]:
            actions_layout.addWidget(button(title, lambda checked=False, value=operation: self.document_tool(value), primary=operation == "translate"))
        actions_layout.addStretch()
        actions_scroll = QScrollArea()
        actions_scroll.setWidgetResizable(True)
        actions_scroll.setWidget(actions)
        split.addWidget(actions_scroll)
        split.setStretchFactor(0, 1)
        split.setStretchFactor(1, 0)
        layout.addWidget(split, 1)
        return page

    def password_for(self, item: LibraryItem):
        value = self.passwords.get(item.id, "")
        try:
            with pdf_ops.open_document(self.store.path(item), value):
                return value
        except Exception:
            with pymupdf.open(self.store.path(item)) as document:
                locked = document.needs_pass
            if not locked:
                raise
        password, accepted = QInputDialog.getText(self, "Mở PDF bảo vệ", "Mật khẩu hiện tại", QLineEdit.Password)
        if not accepted:
            return None
        with pdf_ops.open_document(self.store.path(item), password):
            self.passwords[item.id] = password
        return password

    def open_item(self, identifier):
        item = next((entry for entry in self.store.items if entry.id == identifier), None)
        if item is None:
            return False
        try:
            if self.password_for(item) is None:
                return False
            self.current = item
            self.current_page = 0
            self.page_spec.clear()
            self.document_name.setText(item.name)
            self.stack.setCurrentIndex(4)
            self.render_current_page()
            return True
        except Exception as error:
            self.message(str(error), error=True)
            return False

    def render_current_page(self):
        if self.current is None:
            return
        try:
            with pdf_ops.open_document(self.store.path(self.current), self.passwords.get(self.current.id, "")) as document:
                self.current_page = max(0, min(self.current_page, document.page_count - 1))
                page = document[self.current_page]
                ratio = min(2, 1100 / max(page.rect.width, page.rect.height))
                raster = page.get_pixmap(matrix=pymupdf.Matrix(ratio, ratio), alpha=False)
                image = QImage(raster.samples, raster.width, raster.height, raster.stride, QImage.Format_RGB888).copy()
                pixmap = QPixmap.fromImage(image)
                self.preview.setPixmap(pixmap.scaled(680, 740, Qt.KeepAspectRatio, Qt.SmoothTransformation))
                self.page_counter.setText(f"Trang {self.current_page + 1} / {document.page_count}")
        except Exception as error:
            self.message(str(error), error=True)

    def change_page(self, delta):
        if self.current:
            with pdf_ops.open_document(self.store.path(self.current), self.passwords.get(self.current.id, "")) as document:
                self.current_page = min(max(0, self.current_page + delta), document.page_count - 1)
            self.render_current_page()

    def open_external(self):
        if self.current:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.store.path(self.current))))

    def pages_from_input(self, count, default_current=True):
        text = self.page_spec.text().strip()
        if not text:
            return [self.current_page] if default_current else list(range(count))
        values = []
        try:
            for part in text.replace(" ", "").split(","):
                if "-" in part:
                    first, last = [int(value) for value in part.split("-")]
                    if first > last or last - first > count:
                        raise ValueError()
                    values.extend(range(first - 1, last))
                else:
                    values.append(int(part) - 1)
            if not values or len(set(values)) != len(values) or any(value < 0 or value >= count for value in values):
                raise ValueError()
            return values
        except ValueError:
            raise ValueError(f"Chọn trang từ 1 đến {count}, không lặp. Ví dụ: 1-3,5.")

    def output_operation(self, suffix, callback):
        if self.current is None:
            return
        name = self.current.name + " - " + suffix
        def operation():
            with tempfile.TemporaryDirectory(prefix="scanpdf-operation-") as temporary:
                output = Path(temporary) / "output.pdf"
                callback(output)
                return output.read_bytes()
        def completed(data):
            with tempfile.TemporaryDirectory(prefix="scanpdf-save-") as temporary:
                output = Path(temporary) / "output.pdf"
                output.write_bytes(data)
                item = self.import_pdf(output, name)
                if item:
                    self.open_item(item.id)
        self.run("Đang xử lý PDF…", operation, completed)

    def merge_selected(self):
        items = self.selected_items()
        if len(items) < 2:
            self.message("Chọn ít nhất hai PDF. Thứ tự ghép theo thứ tự sắp xếp đang hiển thị.")
            return
        visible_ids = [self.library_list.item(index).data(Qt.UserRole) for index in range(self.library_list.count())]
        items.sort(key=lambda item: visible_ids.index(item.id))
        try:
            passwords = [self.password_for(item) for item in items]
            if any(value is None for value in passwords):
                return
            paths = [self.store.path(item) for item in items]
            self.current = items[0]
            self.output_operation("Ghép", lambda output: pdf_ops.merge(paths, output, passwords=passwords))
        except Exception as error:
            self.message(str(error), error=True)

    def document_tool(self, operation):
        if self.current is None:
            return
        if operation == "translate":
            self.navigate(2)
            self.translation_document.setCurrentIndex(self.translation_document.findData(self.current.id))
            return
        source = self.store.path(self.current)
        password = self.passwords.get(self.current.id, "")
        try:
            count = pdf_ops.inspect(source, password)["page_count"]
            pages = self.pages_from_input(count)
            if operation == "extract":
                self.output_operation("Trích trang", lambda output: pdf_ops.extract(source, output, pages, password=password))
            elif operation == "rotate":
                self.output_operation("Xoay", lambda output: pdf_ops.rotate(source, output, pages, password=password))
            elif operation == "duplicate":
                self.output_operation("Nhân bản", lambda output: pdf_ops.duplicate(source, output, pages, password=password))
            elif operation == "delete":
                if QMessageBox.question(self, "Xóa trang trong bản sao", f"Bỏ {len(pages)} trang trong PDF mới?") == QMessageBox.Yes:
                    self.output_operation("Bỏ trang", lambda output: pdf_ops.delete_pages(source, output, pages, password=password))
            elif operation == "reorder":
                text, accepted = QInputDialog.getText(self, "Thứ tự trang", "Nhập đủ các trang theo thứ tự mới, ví dụ 3,1,2", text=",".join(str(i + 1) for i in range(count)))
                if accepted:
                    order = [int(value.strip()) - 1 for value in text.split(",")]
                    self.output_operation("Sắp xếp", lambda output: pdf_ops.reorder(source, output, order, password=password))
            elif operation == "insert":
                path, _ = QFileDialog.getOpenFileName(self, "PDF cần chèn", "", "PDF (*.pdf)")
                if path:
                    index, accepted = QInputDialog.getInt(self, "Vị trí chèn", "Chèn trước trang số (số cuối để nối cuối)", self.current_page + 1, 1, count + 1)
                    if accepted:
                        other_password = ""
                        with pymupdf.open(path) as other:
                            if other.needs_pass:
                                other_password, accepted = QInputDialog.getText(self, "Mật khẩu PDF được chèn", "Mật khẩu", QLineEdit.Password)
                        if accepted:
                            self.output_operation("Chèn trang", lambda output: pdf_ops.insert(source, Path(path), output, index - 1, password=password, other_password=other_password))
            elif operation == "images":
                directory = QFileDialog.getExistingDirectory(self, "Thư mục lưu ảnh")
                if directory:
                    encoding, accepted = QInputDialog.getItem(self, "Định dạng ảnh", "Định dạng", ["PNG", "JPEG"], 0, False)
                    if accepted:
                        target = Path(directory) / ("ScanPDF-" + uuid.uuid4().hex[:8])
                        self.run("Đang xuất ảnh…", lambda: pdf_ops.export_images(source, target, format=encoding.lower(), pages=pages, password=password),
                                 lambda values: (self.message(f"Đã xuất {len(values)} ảnh."), QDesktopServices.openUrl(QUrl.fromLocalFile(str(target)))))
            elif operation == "compress":
                quality, accepted = QInputDialog.getInt(self, "Nén PDF", "Chất lượng JPEG (%). Bản nén mất lớp chữ và biểu mẫu; dung lượng có thể tăng.", 75, 30, 95)
                if accepted:
                    self.output_operation("Nén", lambda output: pdf_ops.compress(source, output, quality=quality, password=password))
            elif operation == "watermark":
                text, accepted = QInputDialog.getText(self, "Watermark", "Chữ hiển thị trên tài liệu")
                if accepted:
                    self.output_operation("Watermark", lambda output: pdf_ops.watermark(source, output, text, password=password))
            elif operation == "number":
                start, accepted = QInputDialog.getInt(self, "Đánh số trang", "Số bắt đầu", 1, 1, 1_000_000)
                if accepted:
                    names = ["Dưới giữa", "Dưới trái", "Dưới phải", "Trên giữa", "Trên trái", "Trên phải"]
                    positions = ["bottom-center", "bottom-left", "bottom-right", "top-center", "top-left", "top-right"]
                    value, accepted = QInputDialog.getItem(self, "Vị trí số trang", "Vị trí", names, 0, False)
                    if accepted:
                        self.output_operation("Đánh số", lambda output: pdf_ops.number_pages(source, output, start=start, position=positions[names.index(value)], password=password))
            elif operation == "protect":
                new, accepted = QInputDialog.getText(self, "Đặt mật khẩu", "Mật khẩu mới", QLineEdit.Password)
                if accepted and new:
                    confirmation, accepted = QInputDialog.getText(self, "Xác nhận mật khẩu", "Nhập lại mật khẩu mới", QLineEdit.Password)
                    if accepted:
                        if confirmation != new:
                            self.message("Hai mật khẩu không trùng nhau.")
                        else:
                            self.output_operation("Bảo vệ", lambda output: pdf_ops.protect(source, output, new, password=password))
            elif operation == "unlock":
                self.output_operation("Mở khóa", lambda output: pdf_ops.unlock(source, output, password))
        except Exception as error:
            self.message(str(error), error=True)

    def build_translation(self):
        page, layout = self.page("Dịch PDF sang tiếng Việt", "Giữ bố cục trang, đồ họa và công thức với PDFMathTranslate / BabelDOC.")
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        content = QWidget()
        inner = QVBoxLayout(content)
        inner.setContentsMargins(0, 0, 8, 0)
        inner.setSpacing(18)
        frame, box = card()
        form = QFormLayout()
        form.setSpacing(12)
        self.translation_document = QComboBox()
        self.provider = QComboBox()
        self.provider.addItem("Google · Miễn phí qua mạng", "google")
        self.provider.addItem("Bing · Miễn phí, chọn ngôn ngữ nguồn", "bing")
        self.provider.addItem("API riêng tương thích OpenAI", "openai")
        self.provider.setCurrentIndex(max(0, self.provider.findData(self.preferences.get("service", "google"))))
        self.source_language = QComboBox()
        for code, title in [("auto", "Tự nhận diện"), ("en", "Tiếng Anh"), ("zh", "Tiếng Trung"),
                            ("ja", "Tiếng Nhật"), ("ko", "Tiếng Hàn"), ("fr", "Tiếng Pháp"),
                            ("de", "Tiếng Đức"), ("es", "Tiếng Tây Ban Nha"), ("ru", "Tiếng Nga"),
                            ("pt", "Tiếng Bồ Đào Nha"), ("it", "Tiếng Ý")]:
            self.source_language.addItem(title, code)
        self.source_language.setCurrentIndex(max(0, self.source_language.findData(self.preferences.get("source", "auto"))))
        self.api_url = QLineEdit(self.preferences.get("base_url", "https://api.openai.com/v1"))
        self.api_model = QLineEdit(self.preferences.get("model", "gpt-4o-mini"))
        self.api_key = QLineEdit()
        self.api_key.setEchoMode(QLineEdit.Password)
        self.api_key.setPlaceholderText("API key của bạn · Lưu trong Windows Credential Manager")
        try:
            import keyring
            self.api_key.setText(keyring.get_password("ScanPDF", "translation-api-key") or "")
        except Exception:
            pass
        form.addRow("Tài liệu", self.translation_document)
        form.addRow("Dịch vụ", self.provider)
        form.addRow("Ngôn ngữ nguồn", self.source_language)
        form.addRow("Ngôn ngữ đích", label("Tiếng Việt"))
        self.api_section = QWidget()
        api_form = QFormLayout(self.api_section)
        api_form.setContentsMargins(0, 0, 0, 0)
        api_form.addRow("Địa chỉ API", self.api_url)
        api_form.addRow("Model", self.api_model)
        api_form.addRow("API key", self.api_key)
        form.addRow(self.api_section)
        box.addLayout(form)
        self.provider.currentIndexChanged.connect(lambda: self.api_section.setVisible(self.provider.currentData() == "openai"))
        self.api_section.setVisible(self.provider.currentData() == "openai")
        self.translation_disclosure = label(
            "Khi dịch, văn bản được gửi đến nhà cung cấp bạn chọn; bố cục được xử lý trên PC. "
            "Lần đầu có thể tải khoảng 350 MB model và font. Dịch miễn phí phụ thuộc giới hạn của nhà cung cấp.", "Muted")
        box.addWidget(self.translation_disclosure)
        actions = QHBoxLayout()
        actions.addWidget(button("Lưu cấu hình cho iPhone", self.apply_provider_settings))
        actions.addStretch()
        self.translate_button = button("Dịch tài liệu → Tiếng Việt", self.start_translation, primary=True)
        actions.addWidget(self.translate_button)
        box.addLayout(actions)
        inner.addWidget(frame)
        status_frame, status_box = card()
        status_box.addWidget(label("Tiến trình & bản dịch", "Subheading"))
        self.job_list = QListWidget()
        self.job_list.setMaximumHeight(135)
        self.job_list.currentItemChanged.connect(self.select_job)
        status_box.addWidget(self.job_list)
        self.translation_progress = QProgressBar()
        self.translation_progress.setRange(0, 100)
        self.translation_progress.setValue(0)
        status_box.addWidget(self.translation_progress)
        self.translation_status = label("Chọn PDF để bắt đầu. Tác vụ từ iPhone cũng xuất hiện tại đây.", "Muted")
        status_box.addWidget(self.translation_status)
        outputs = QHBoxLayout()
        self.cancel_translation_button = button("Dừng dịch", self.cancel_translation)
        self.cancel_translation_button.setEnabled(False)
        self.save_mono_button = button("Lưu PDF tiếng Việt", lambda: self.save_translation("mono"))
        self.save_dual_button = button("Lưu PDF song ngữ", lambda: self.save_translation("dual"))
        self.save_mono_button.setEnabled(False)
        self.save_dual_button.setEnabled(False)
        outputs.addWidget(self.cancel_translation_button)
        outputs.addStretch()
        outputs.addWidget(self.save_mono_button)
        outputs.addWidget(self.save_dual_button)
        status_box.addLayout(outputs)
        inner.addWidget(status_frame)
        inner.addWidget(label(
            "Phù hợp nhất với PDF gốc có văn bản chọn được. Bản scan chỉ có ảnh hoặc lớp OCR ẩn chưa hỗ trợ dịch giữ bố cục. "
            "Công thức được giữ nguyên; chú thích bằng chữ được dịch. Chữ nằm bên trong một ảnh minh họa có thể vẫn là ngôn ngữ gốc. "
            "Bố cục phức tạp cần soát lại; lưu PDF song ngữ để đối chiếu.", "Muted"))
        inner.addStretch()
        scroll.setWidget(content)
        layout.addWidget(scroll, 1)
        return page

    def refresh_translation_documents(self):
        selected = self.translation_document.currentData()
        self.translation_document.clear()
        for item in sorted(self.store.items, key=lambda value: -value.created_at):
            self.translation_document.addItem(item.name, item.id)
        index = self.translation_document.findData(selected)
        if index >= 0:
            self.translation_document.setCurrentIndex(index)

    def apply_provider_settings(self, checked=False, silent=False):
        try:
            service = self.provider.currentData()
            source = self.source_language.currentData()
            if service == "bing" and source == "auto":
                raise ValueError("Bing yêu cầu chọn ngôn ngữ nguồn. Chọn Google để tự nhận diện ngôn ngữ.")
            api_key = self.api_key.text().strip() if service == "openai" else None
            base_url = self.api_url.text().strip() if service == "openai" else None
            model = self.api_model.text().strip() if service == "openai" else None
            if service == "openai" and (not api_key or not base_url or not model):
                raise ValueError("Điền địa chỉ API, model và API key trước khi dùng API riêng.")
            settings = TranslationSettings(service=service, source=source, target="vi",
                                           api_key=api_key, base_url=base_url, model=model)
            settings.validate()
            if api_key and not silent:
                import keyring
                keyring.set_password("ScanPDF", "translation-api-key", api_key)
            self.preferences = {"service": service, "source": source,
                                "base_url": self.api_url.text().strip(), "model": self.api_model.text().strip()}
            temporary = self.preferences_file.with_suffix(".pending")
            temporary.write_text(json.dumps(self.preferences, ensure_ascii=False, indent=2), encoding="utf-8")
            temporary.replace(self.preferences_file)
            self.manager.set_default_settings(settings)
            if not silent:
                self.statusBar().showMessage("Đã lưu cấu hình dịch. iPhone sẽ dùng cấu hình này.", 7000)
            return settings
        except Exception as error:
            if not silent:
                self.message(str(error), error=True)
            return None

    def start_translation(self):
        identifier = self.translation_document.currentData()
        item = next((entry for entry in self.store.items if entry.id == identifier), None)
        if item is None:
            self.message("Nhập một PDF vào thư viện trước khi dịch.")
            return
        settings = self.apply_provider_settings()
        if settings is None:
            return
        try:
            password = self.password_for(item)
            if password is None:
                return
            source = self.store.path(item)
            def submit():
                if password:
                    with tempfile.TemporaryDirectory(prefix="scanpdf-translate-input-") as temporary:
                        unencrypted = pdf_ops.unlock(source, Path(temporary) / "input.pdf", password)
                        return self.manager.submit_file(unencrypted, settings, filename=item.name + ".pdf")
                return self.manager.submit_file(source, settings, filename=item.name + ".pdf")
            def ready(job):
                self.active_job = job["id"]
                if not hasattr(self, "local_jobs"):
                    self.local_jobs = {}
                self.local_jobs[job["id"]] = (item.name, password)
                self.poll_job()
            self.run("Đang kiểm tra PDF và đưa vào hàng đợi dịch…", submit, ready)
        except Exception as error:
            self.message(str(error), error=True)

    def select_job(self, entry, previous=None):
        if entry:
            self.active_job = entry.data(Qt.UserRole)

    def poll_job(self):
        try:
            jobs = self.manager.list_jobs()
            selected = self.active_job
            self.job_list.blockSignals(True)
            self.job_list.clear()
            titles = {"queued": "Đang chờ", "running": "Đang dịch", "completed": "Hoàn tất",
                      "failed": "Có lỗi", "cancelled": "Đã dừng"}
            for state in jobs:
                entry = QListWidgetItem(f"{state['filename']}   ·   {titles.get(state['status'], state['status'])}   ·   {state['progress']:.0f}%")
                entry.setData(Qt.UserRole, state["id"])
                self.job_list.addItem(entry)
                if state["id"] == selected:
                    self.job_list.setCurrentItem(entry)
            self.job_list.blockSignals(False)
            if not self.active_job:
                return
            state = self.manager.status(self.active_job)
            self.translation_progress.setValue(int(state["progress"]))
            self.translation_status.setText(state.get("error") or state.get("message") or state.get("stage") or titles.get(state["status"], ""))
            self.cancel_translation_button.setEnabled(state["status"] in ("queued", "running"))
            self.save_mono_button.setEnabled(state["status"] == "completed" and "mono" in state["outputs"])
            self.save_dual_button.setEnabled(state["status"] == "completed" and "dual" in state["outputs"])
            for job in jobs:
                if job["status"] == "completed" and job["id"] not in self.imported_jobs and job["id"] in getattr(self, "local_jobs", {}):
                    name, password = self.local_jobs[job["id"]]
                    source = self.manager.download_path(job["id"], "mono")
                    if password:
                        with tempfile.TemporaryDirectory(prefix="scanpdf-translate-protected-") as temporary:
                            protected = pdf_ops.protect(source, Path(temporary) / "output.pdf", password)
                            self.store.import_file(protected, name + " - Tiếng Việt")
                    else:
                        self.store.import_file(source, name + " - Tiếng Việt")
                    self.imported_jobs.add(job["id"])
                    self.refresh_library()
                    self.statusBar().showMessage("Đã lưu bản dịch tiếng Việt vào thư viện.", 8000)
        except Exception as error:
            self.translation_status.setText(str(error))

    def cancel_translation(self):
        if self.active_job:
            self.manager.cancel(self.active_job)
            self.poll_job()

    def save_translation(self, kind):
        if not self.active_job:
            return
        try:
            state = self.manager.status(self.active_job)
            source = self.manager.download_path(self.active_job, kind)
            suffix = " - Tiếng Việt" if kind == "mono" else " - Song ngữ"
            name, password = getattr(self, "local_jobs", {}).get(self.active_job, (Path(state["filename"]).stem, ""))
            if password:
                with tempfile.TemporaryDirectory(prefix="scanpdf-save-protected-") as temporary:
                    protected = pdf_ops.protect(source, Path(temporary) / "output.pdf", password)
                    self.save_copy(protected, name + suffix + ".pdf")
            else:
                self.save_copy(source, name + suffix + ".pdf")
        except Exception as error:
            self.message(str(error), error=True)

    def build_connection(self):
        page, layout = self.page("Kết nối iPhone / iPad", "Bật máy chủ dịch trên PC, rồi ghép nối ScanPDF iOS trong cùng mạng Wi-Fi.")
        frame, box = card()
        form = QFormLayout()
        self.lan_address = QComboBox()
        addresses = set()
        try:
            addresses.update(entry[4][0] for entry in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET))
        except OSError:
            pass
        addresses = {value for value in addresses if not value.startswith("127.") and value != "0.0.0.0"}
        self.lan_address.addItems(sorted(addresses) or ["127.0.0.1"])
        self.lan_address.setEditable(True)
        self.server_port = QSpinBox()
        self.server_port.setRange(1024, 65535)
        self.server_port.setValue(8765)
        self.server_url = QLineEdit()
        self.server_url.setReadOnly(True)
        self.pair_token = QLineEdit()
        self.pair_token.setReadOnly(True)
        self.pair_token.setEchoMode(QLineEdit.Password)
        self.pair_token.setText(self.get_pair_token())
        form.addRow("Địa chỉ PC", self.lan_address)
        form.addRow("Cổng", self.server_port)
        form.addRow("URL trên iPhone", self.server_url)
        form.addRow("Mã ghép nối", self.pair_token)
        box.addLayout(form)
        token_actions = QHBoxLayout()
        show_token = QCheckBox("Hiện mã")
        show_token.toggled.connect(lambda shown: self.pair_token.setEchoMode(QLineEdit.Normal if shown else QLineEdit.Password))
        token_actions.addWidget(show_token)
        token_actions.addWidget(button("Sao chép URL", lambda: QApplication.clipboard().setText(self.server_url.text())))
        token_actions.addWidget(button("Sao chép mã", lambda: QApplication.clipboard().setText(self.pair_token.text())))
        token_actions.addStretch()
        box.addLayout(token_actions)
        self.bridge_status = label("Máy chủ đang tắt.", "Muted")
        box.addWidget(self.bridge_status)
        self.bridge_button = button("Bật máy chủ dịch", self.toggle_bridge, primary=True)
        box.addWidget(self.bridge_button)
        layout.addWidget(frame)
        layout.addWidget(label(
            "1. Kết nối PC và iPhone vào cùng Wi-Fi.\n"
            "2. Bật máy chủ; nếu Windows hỏi, cho phép ScanPDF trên mạng riêng.\n"
            "3. Trên iPhone: Công cụ → Dịch tiếng Việt → Kết nối PC, nhập URL và mã ghép nối.\n"
            "4. Chọn PDF và dịch. Giữ PC mở cho đến khi nhận bản dịch.", "Muted"))
        layout.addWidget(label(
            "Chỉ bật trên mạng riêng tin cậy. Kết nối HTTP trong Wi-Fi không mã hóa dữ liệu; mã ghép nối giới hạn truy cập. "
            "API key chỉ nằm trên PC. Dữ liệu tác vụ tạm được dọn theo thời hạn hiển thị trong hướng dẫn.", "Muted"))
        layout.addStretch()
        self.lan_address.currentTextChanged.connect(self.update_server_url)
        self.server_port.valueChanged.connect(self.update_server_url)
        self.update_server_url()
        return page

    def get_pair_token(self):
        import secrets
        try:
            import keyring
            value = keyring.get_password("ScanPDF", "pair-token")
            if value and len(value) >= 24:
                return value
            value = secrets.token_urlsafe(24)
            keyring.set_password("ScanPDF", "pair-token", value)
            return value
        except Exception:
            return secrets.token_urlsafe(24)

    def update_server_url(self, *_):
        self.server_url.setText(f"http://{self.lan_address.currentText().strip()}:{self.server_port.value()}")

    def toggle_bridge(self):
        if self.bridge:
            self.bridge.stop()
            self.bridge = None
            self.bridge_status.setText("Máy chủ đang tắt.")
            self.bridge_button.setText("Bật máy chủ dịch")
            self.server_port.setEnabled(True)
        else:
            try:
                self.bridge = BridgeServer(self.manager, self.pair_token.text(), host="0.0.0.0", port=self.server_port.value())
                self.bridge.start()
                self.bridge_status.setText("Máy chủ đang bật. Chỉ thiết bị có mã ghép nối mới gửi được tài liệu.")
                self.bridge_button.setText("Tắt máy chủ dịch")
                self.server_port.setEnabled(False)
            except Exception as error:
                self.bridge = None
                self.message(str(error), error=True)

    def scan_dialog(self):
        dialog = ScanDialog(self)
        if dialog.exec() == QDialog.Accepted and dialog.paths:
            paths = list(dialog.paths)
            paper = dialog.paper.currentData()
            filter_value = dialog.filter.currentData()
            name = dialog.name.text().strip() or "Bản quét"
            def operation():
                with tempfile.TemporaryDirectory(prefix="scanpdf-images-") as temporary:
                    output = pdf_ops.images_to_pdf(paths, Path(temporary) / "scan.pdf", paper=paper, filter=filter_value)
                    return output.read_bytes()
            def complete(data):
                with tempfile.TemporaryDirectory(prefix="scanpdf-scan-save-") as temporary:
                    path = Path(temporary) / "scan.pdf"
                    path.write_bytes(data)
                    item = self.import_pdf(path, name)
                    if item:
                        self.open_item(item.id)
                dialog.cleanup()
            self.run("Đang tạo PDF từ ảnh…", operation, complete, failed=dialog.cleanup)
        else:
            dialog.cleanup()

    def closeEvent(self, event):
        if self.busy:
            self.message("Chờ thao tác PDF hoàn tất trước khi đóng ứng dụng.")
            event.ignore()
            return
        if any(state["status"] in ("queued", "running") for state in self.manager.list_jobs()):
            if QMessageBox.question(self, "Dừng dịch?", "Đóng ứng dụng sẽ dừng các tác vụ đang dịch, kể cả tác vụ từ iPhone. Bạn muốn đóng?") != QMessageBox.Yes:
                event.ignore()
                return
        self.job_timer.stop()
        if self.bridge:
            self.bridge.stop()
        self.manager.shutdown()
        event.accept()


class ScanDialog(QDialog):
    def __init__(self, parent):
        super().__init__(parent)
        self.paths: list[Path] = []
        self.temporary = tempfile.TemporaryDirectory(prefix="scanpdf-camera-")
        self.setWindowTitle("Ảnh / Camera thành PDF")
        self.resize(780, 650)
        layout = QVBoxLayout(self)
        layout.addWidget(label("Tạo PDF từ ảnh hoặc webcam", "Subheading"))
        layout.addWidget(label("Chọn nhiều ảnh hoặc chụp giấy bằng webcam. Sắp giấy thẳng và đủ sáng; bản PC giữ nguyên khung ảnh.", "Muted"))
        controls = QHBoxLayout()
        controls.addWidget(button("Thêm ảnh", self.add_images))
        controls.addWidget(button("Chụp webcam", self.open_camera))
        controls.addWidget(button("Xóa ảnh đã chọn", self.remove_image))
        layout.addLayout(controls)
        self.images = QListWidget()
        layout.addWidget(self.images, 1)
        ordering = QHBoxLayout()
        ordering.addWidget(button("↑ Đưa lên", lambda: self.move_image(-1)))
        ordering.addWidget(button("↓ Đưa xuống", lambda: self.move_image(1)))
        ordering.addStretch()
        layout.addLayout(ordering)
        form = QFormLayout()
        self.name = QLineEdit("Bản quét " + datetime.now().strftime("%d-%m-%Y"))
        self.paper = QComboBox()
        for title, value in [("Theo ảnh", "original"), ("A4", "a4"), ("Letter", "letter")]:
            self.paper.addItem(title, value)
        self.filter = QComboBox()
        for title, value in [("Màu gốc", "original"), ("Thang xám", "grayscale"), ("Đen trắng", "blackAndWhite")]:
            self.filter.addItem(title, value)
        form.addRow("Tên PDF", self.name)
        form.addRow("Khổ giấy", self.paper)
        form.addRow("Bộ lọc", self.filter)
        layout.addLayout(form)
        actions = QDialogButtonBox(QDialogButtonBox.Cancel | QDialogButtonBox.Save)
        actions.button(QDialogButtonBox.Cancel).setText("Hủy")
        actions.button(QDialogButtonBox.Save).setText("Tạo PDF")
        actions.accepted.connect(self.confirm)
        actions.rejected.connect(self.reject)
        layout.addWidget(actions)

    def refresh(self):
        self.images.clear()
        for index, path in enumerate(self.paths):
            self.images.addItem(f"Trang {index + 1}   ·   {path.name}")

    def add_images(self):
        paths, _ = QFileDialog.getOpenFileNames(self, "Thêm ảnh", "", "Ảnh (*.png *.jpg *.jpeg *.bmp *.tif *.tiff *.webp)")
        self.paths.extend(Path(path) for path in paths)
        self.refresh()

    def remove_image(self):
        index = self.images.currentRow()
        if index >= 0:
            self.paths.pop(index)
            self.refresh()

    def move_image(self, delta):
        index = self.images.currentRow()
        destination = index + delta
        if 0 <= index < len(self.paths) and 0 <= destination < len(self.paths):
            self.paths[index], self.paths[destination] = self.paths[destination], self.paths[index]
            self.refresh()
            self.images.setCurrentRow(destination)

    def confirm(self):
        if not self.paths:
            QMessageBox.information(self, "Chưa có ảnh", "Thêm ít nhất một ảnh.")
            return
        if len(self.paths) > 40:
            QMessageBox.information(self, "Quá nhiều ảnh", "Mỗi lần tạo tối đa 40 trang. Hãy chia thành các tài liệu nhỏ rồi ghép PDF.")
            return
        self.accept()

    def open_camera(self):
        try:
            from PySide6.QtMultimedia import QCamera, QImageCapture, QMediaCaptureSession, QMediaDevices
            from PySide6.QtMultimediaWidgets import QVideoWidget
            devices = QMediaDevices.videoInputs()
            if not devices:
                raise ValueError("Không tìm thấy webcam. Bạn có thể nhập ảnh có sẵn.")
            dialog = QDialog(self)
            dialog.setWindowTitle("Chụp tài liệu bằng webcam")
            dialog.resize(720, 590)
            box = QVBoxLayout(dialog)
            video = QVideoWidget()
            box.addWidget(video, 1)
            camera = QCamera(devices[0], dialog)
            capture = QImageCapture(dialog)
            session = QMediaCaptureSession(dialog)
            session.setCamera(camera)
            session.setImageCapture(capture)
            session.setVideoOutput(video)
            status = label("Giữ giấy thẳng trong khung hình.", "Muted")
            box.addWidget(status)
            take = button("Chụp trang", capture.capture, primary=True)
            take.setEnabled(False)
            capture.readyForCaptureChanged.connect(take.setEnabled)
            box.addWidget(take)
            box.addWidget(button("Xong", dialog.accept))
            def captured(identifier, image):
                path = Path(self.temporary.name) / f"camera-{uuid.uuid4().hex}.jpg"
                if image.save(str(path), "JPEG", 95):
                    self.paths.append(path)
                    self.refresh()
                    status.setText(f"Đã chụp {len(self.paths)} trang. Tiếp tục chụp hoặc nhấn Xong.")
                else:
                    status.setText("Không lưu được ảnh chụp.")
            capture.imageCaptured.connect(captured)
            capture.errorOccurred.connect(lambda identifier, error, text: status.setText(text))
            camera.errorOccurred.connect(lambda error, text: status.setText(text))
            camera.start()
            dialog.exec()
            camera.stop()
            session.setCamera(None)
        except Exception as error:
            QMessageBox.warning(self, "Không mở được camera", str(error))

    def cleanup(self):
        self.temporary.cleanup()
