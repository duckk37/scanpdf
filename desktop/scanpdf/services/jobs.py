"""Translation jobs shared by the Qt application and the authenticated LAN API.

The layout engine runs in a spawned process, never in the GUI or HTTP event loop.
Only one translation runs at a time to bound ONNX/model memory usage.
"""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import json
import math
import multiprocessing
import queue
import re
import shutil
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Callable

import pymupdf

from .pdf_ops import PDFError, open_document

MAX_UPLOAD_BYTES = 100 * 1024 * 1024
MAX_PENDING_JOBS = 8
RETENTION_SECONDS = 24 * 60 * 60
TERMINAL = {"completed", "failed", "cancelled"}


@dataclass(frozen=True)
class TranslationSettings:
    service: str = "google"
    source: str = "auto"
    target: str = "vi"
    api_key: str | None = field(default=None, repr=False)
    base_url: str | None = None
    model: str | None = None
    pages: str | None = None

    def validate(self) -> "TranslationSettings":
        if self.service not in {"google", "bing", "openai", "server"}:
            raise PDFError("Dịch vụ dịch không được hỗ trợ.")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{1,19}", self.source) or self.target != "vi":
            raise PDFError("Chọn ngôn ngữ nguồn hợp lệ; bản dịch hiện hỗ trợ tiếng Việt.")
        if self.service == "bing" and self.source == "auto":
            raise PDFError("Bing cần chọn ngôn ngữ nguồn cụ thể. Dùng Google để tự nhận diện.")
        if self.service == "openai":
            if not self.api_key or not self.model or len(self.api_key) > 4096 or len(self.model) > 200:
                raise PDFError("Nhập API key và tên model cho dịch vụ API riêng trên PC.")
            if self.base_url:
                from urllib.parse import urlsplit
                parsed = urlsplit(self.base_url)
                if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.username or parsed.query or parsed.fragment:
                    raise PDFError("Địa chỉ API không hợp lệ. Dùng URL http/https không có mật khẩu hoặc query.")
        if self.pages and not re.fullmatch(r"\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*", self.pages):
            raise PDFError("Trang cần dịch có dạng 1,3-5 (bắt đầu từ 1).")
        return self


def validate_translation_pdf(path: Path, settings: TranslationSettings) -> None:
    with open_document(path) as document:
        if len(document) > 500:
            raise PDFError("Dịch tối đa 500 trang mỗi công việc. Hãy tách PDF trước.")
        if settings.pages:
            for part in settings.pages.split(","):
                bounds = [int(p) for p in part.split("-")]
                if min(bounds) < 1 or max(bounds) > len(document) or bounds[0] > bounds[-1]:
                    raise PDFError("Trang cần dịch nằm ngoài PDF.")
        selected = set(range(len(document)))
        if settings.pages:
            selected = set()
            for part in settings.pages.split(","):
                bounds = [int(p) for p in part.split("-")]
                selected.update(range(bounds[0] - 1, bounds[-1]))
        has_text = False
        for index in selected:
            page = document[index]
            text = page.get_text().strip()
            has_text = has_text or sum(c.isalpha() for c in text) >= 5
            area = page.rect.get_area()
            large_image = any((info["bbox"] and (page.rect & pymupdf.Rect(info["bbox"])).get_area() >= area * .80)
                              for info in page.get_image_info())
            if large_image:
                traces = page.get_texttrace()
                visible_chars = sum(len(trace.get("chars", ())) for trace in traces
                                    if trace.get("type") != 3 and trace.get("opacity", 1) > .01)
                hidden_chars = sum(len(trace.get("chars", ())) for trace in traces
                                   if trace.get("type") == 3 or trace.get("opacity", 1) <= .01)
                # A short native watermark must not make an image scan appear to
                # have a translatable native body. Hidden OCR stays unsupported.
                if visible_chars < 30 or (hidden_chars >= 20 and hidden_chars > visible_chars):
                    raise PDFError(f"Trang {index + 1} là bản scan/ảnh có lớp OCR ẩn. Dịch giữ bố cục hiện cần PDF có chữ thật; chưa hỗ trợ scan.")
        if not has_text:
            raise PDFError("PDF không có lớp chữ có thể dịch. Bản scan/ảnh chưa được hỗ trợ dịch giữ bố cục.")


def _safe_error(error: Exception | str, settings: TranslationSettings) -> str:
    text = str(error)
    if settings.service in {"google", "bing"} and ("429" in text or "Too Many Requests" in text):
        return "Dịch vụ miễn phí đang giới hạn truy cập. Hãy thử lại sau hoặc chọn Bing với ngôn ngữ nguồn cụ thể / API riêng."
    for secret in (settings.api_key, settings.base_url):
        if secret:
            text = text.replace(secret, "[đã ẩn]")
    text = re.sub(r"(?i)(authorization|api[_ -]?key|bearer)[=: ]+[^\s,;}]+", r"\1 [đã ẩn]", text)
    text = re.sub(r"https?://[^\s]+", "[dịch vụ mạng]", text)
    return text[:1500] or "Không thể hoàn thành bản dịch."


def _upstream_settings(settings: TranslationSettings, output: Path):
    from pdf2zh_next.config.model import SettingsModel
    engine = {"translate_engine_type": {"google": "Google", "bing": "Bing", "openai": "OpenAI"}[settings.service]}
    if settings.service == "openai":
        engine.update(openai_api_key=settings.api_key, openai_base_url=settings.base_url,
                      openai_model=settings.model, openai_timeout="60")
    return SettingsModel.model_validate({
        "translate_engine_settings": engine,
        "translation": {"lang_in": settings.source, "lang_out": "vi", "output": str(output),
                        "qps": 2, "pool_max_workers": 2, "no_auto_extract_glossary": True,
                        "min_text_length": 3},
        "pdf": {"pages": settings.pages, "no_dual": False, "no_mono": False,
                "watermark_output_mode": "no_watermark", "translate_table_text": False,
                "ocr_workaround": False, "auto_enable_ocr_workaround": False,
                "skip_scanned_detection": False, "no_remove_non_formula_lines": True},
        "report_interval": .3,
    })


def _engine_worker(input_path: str, output_dir: str, raw_settings: dict, connection) -> None:
    import asyncio
    import logging
    settings = TranslationSettings(**raw_settings)
    try:
        # Engine imports can load native ONNX libraries; isolate them in this worker.
        from pdf2zh_next.high_level import create_babeldoc_config
        from babeldoc.format.pdf.high_level import async_translate
        import requests

        # Free-provider adapters omit HTTP timeouts. Bound their requests inside
        # this isolated process; cancellation also terminates the worker tree.
        original_request = requests.sessions.Session.request
        def bounded_request(session, *args, **kwargs):
            kwargs.setdefault("timeout", (15, 45))
            return original_request(session, *args, **kwargs)
        requests.sessions.Session.request = bounded_request
        # Provider exceptions may contain request URLs or credentials. The
        # parent receives only _safe_error and never raw upstream log output.
        logging.basicConfig(handlers=[logging.NullHandler()], force=True)
        if settings.service == "google":
            from .free_translate import install_google_adapter
            install_google_adapter()
        upstream = _upstream_settings(settings, Path(output_dir))
        # Built-in PDF fonts can lack a family descriptor. Infer the dominant
        # body family so a Helvetica document keeps sans-serif Vietnamese text.
        family_weights = {"serif": 0, "sans-serif": 0}
        with open_document(input_path) as document:
            for page in list(document.pages(0, min(3, len(document)))):
                for block in page.get_text("dict")["blocks"]:
                    for line in block.get("lines", []):
                        for span in line["spans"]:
                            count = sum(c.isalpha() for c in span.get("text", ""))
                            if count >= 5:
                                family_weights["serif" if span.get("flags", 0) & 4 else "sans-serif"] += count
        if max(family_weights.values()) > 0:
            upstream.translation.primary_font_family = max(family_weights, key=family_weights.get)
        configuration = create_babeldoc_config(upstream, Path(input_path))

        async def consume():
            async for event in async_translate(configuration):
                event_type = event.get("type")
                if event_type == "error":
                    raise RuntimeError(event.get("error", "Engine dịch thất bại."))
                if event_type == "finish":
                    result = event["translate_result"]
                    outputs = {}
                    for kind in ("mono", "dual"):
                        value = getattr(result, f"no_watermark_{kind}_pdf_path", None) or getattr(result, f"{kind}_pdf_path", None)
                        if value:
                            outputs[kind] = str(value)
                    connection.send({"type": "finish", "outputs": outputs})
                    return
                if event_type in {"progress_start", "progress_update", "progress_end"}:
                    connection.send({"type": "progress", "progress": event.get("overall_progress", 0),
                                     "stage": str(event.get("stage", "Đang dịch"))})
            raise RuntimeError("Engine kết thúc nhưng không tạo PDF dịch.")

        asyncio.run(consume())
    except BaseException as error:
        with contextlib.suppress(BrokenPipeError, EOFError, OSError):
            connection.send({"type": "error", "error": _safe_error(error, settings)})
    finally:
        connection.close()


def _stop_process_tree(process) -> None:
    # Upstream starts a child for BabelDOC. Stop descendants as well as the wrapper.
    import psutil
    with contextlib.suppress(psutil.Error):
        parent = psutil.Process(process.pid)
        children = parent.children(recursive=True)
        for child in reversed(children):
            with contextlib.suppress(psutil.Error):
                child.kill()
        with contextlib.suppress(psutil.Error):
            parent.kill()
        psutil.wait_procs(children, timeout=2)
    if process.is_alive():
        process.kill()
    process.join(timeout=3)


def _run_engine(input_path: Path, output: Path, settings: TranslationSettings,
                report: Callable[[dict], None], cancelled: threading.Event) -> dict[str, str]:
    context = multiprocessing.get_context("spawn")
    receive, send = context.Pipe(duplex=False)
    process = context.Process(target=_engine_worker, args=(str(input_path), str(output), asdict(settings), send))
    process.start()
    send.close()
    started = time.monotonic()
    result = None
    try:
        while True:
            if cancelled.is_set():
                return {}
            if time.monotonic() - started > 90 * 60:
                raise RuntimeError("Công việc vượt quá 90 phút. Hãy chia PDF thành phần nhỏ hơn.")
            if receive.poll(.15):
                try:
                    event = receive.recv()
                except EOFError:
                    break
                if event["type"] == "finish":
                    result = event["outputs"]
                    break
                if event["type"] == "error":
                    raise RuntimeError(event["error"])
                report(event)
            elif not process.is_alive():
                break
        if not result:
            raise RuntimeError(f"Engine dịch kết thúc không có kết quả (mã {process.exitcode}).")
        return result
    finally:
        receive.close()
        _stop_process_tree(process)


class JobManager:
    def __init__(self, root: str | Path, *, runner=None):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self._cleanup_expired()
        self._runner = runner or _run_engine
        self._lock = threading.RLock()
        self._jobs: dict[str, dict] = {}
        self._requests: dict[str, tuple[str, str]] = {}
        self._cancellations: dict[str, threading.Event] = {}
        self._queue: queue.Queue = queue.Queue()
        self._closed = False
        self._pending_submissions = 0
        self._defaults = TranslationSettings()
        self._thread = threading.Thread(target=self._work, name="scanpdf-jobs", daemon=True)
        self._thread.start()

    def _remove_job_directory(self, directory: Path) -> None:
        # Validate the final Windows target before any recursive removal.
        resolved = directory.resolve()
        if directory.is_symlink() or directory.is_junction() or not resolved.is_relative_to(self.root) or resolved.parent != self.root:
            raise PDFError("Thư mục tạm nằm ngoài vùng lưu trữ ứng dụng.")
        try:
            uuid.UUID(resolved.name)
        except ValueError:
            raise PDFError("Tên thư mục tạm không hợp lệ.")
        shutil.rmtree(resolved, ignore_errors=True)

    def _remove_output(self, job_id: str) -> None:
        directory = self.root / job_id / "output"
        resolved = directory.resolve()
        if directory.is_symlink() or directory.is_junction() or resolved != (self.root / job_id / "output"):
            raise PDFError("Thư mục kết quả nằm ngoài vùng lưu trữ ứng dụng.")
        if not resolved.is_relative_to(self.root):
            raise PDFError("Thư mục kết quả không hợp lệ.")
        shutil.rmtree(resolved, ignore_errors=True)

    def _cleanup_expired(self) -> None:
        now = time.time()
        for directory in self.root.iterdir():
            if not directory.is_dir() or directory.is_symlink() or directory.is_junction():
                continue
            try:
                uuid.UUID(directory.name)
                if now - directory.stat().st_mtime > RETENTION_SECONDS:
                    self._remove_job_directory(directory)
            except (ValueError, OSError):
                continue

    @property
    def default_settings(self) -> TranslationSettings:
        with self._lock:
            return self._defaults

    def set_default_settings(self, settings: TranslationSettings) -> None:
        settings.validate()
        if settings.service == "server":
            raise PDFError("Cấu hình PC cần chọn một dịch vụ cụ thể.")
        with self._lock:
            self._defaults = settings

    @property
    def engine_ready(self) -> bool:
        return importlib.util.find_spec("pdf2zh_next") is not None

    def _resolve(self, settings: TranslationSettings | dict | None) -> TranslationSettings:
        settings = TranslationSettings(**settings) if isinstance(settings, dict) else settings or self.default_settings
        if settings.service == "server":
            settings = replace(self.default_settings, source=settings.source, target=settings.target, pages=settings.pages)
        return settings.validate()

    def submit_file(self, path, settings=None, filename=None, request_id=None) -> dict:
        path = Path(path)
        if path.stat().st_size > MAX_UPLOAD_BYTES:
            raise PDFError("PDF vượt quá giới hạn 100 MB.")
        return self.submit_bytes(path.read_bytes(), filename or path.name, settings, request_id=request_id)

    def submit_bytes(self, data: bytes, filename: str, settings=None, request_id=None) -> dict:
        settings = self._resolve(settings)
        if not data or len(data) > MAX_UPLOAD_BYTES:
            raise PDFError("PDF trống hoặc vượt quá giới hạn 100 MB.")
        request_id = str(uuid.UUID(str(request_id))) if request_id else None
        fingerprint = hashlib.sha256(data + json.dumps(asdict(settings), sort_keys=True).encode()).hexdigest()
        with self._lock:
            if self._closed:
                raise PDFError("Dịch vụ đang đóng.")
            if request_id in self._requests:
                previous_id, previous_hash = self._requests[request_id]
                if previous_hash != fingerprint:
                    raise PDFError("Request ID đã được dùng cho PDF hoặc cấu hình khác.")
                return self.status(previous_id)
            if self._pending_submissions + sum(job["status"] not in TERMINAL for job in self._jobs.values()) >= MAX_PENDING_JOBS:
                raise PDFError("Hàng đợi đã đầy. Hãy chờ một công việc hoàn thành.")
            self._pending_submissions += 1
        job_id = str(uuid.uuid4())
        directory = self.root / job_id
        committed = False
        try:
            directory.mkdir()
            source = directory / "input.pdf"
            # PDF parsing/image detection can be expensive; status/cancel and the
            # GUI polling thread must remain responsive during this validation.
            source.write_bytes(data)
            validate_translation_pdf(source, settings)
            filename = Path(filename.replace("\\", "/")).name[:200] or "document.pdf"
            now = time.time()
            job = {"id": job_id, "filename": filename, "status": "queued", "progress": 0,
                   "stage": "Đang chờ", "message": "Đang chờ lượt dịch.", "error": None,
                   "outputs": [], "created_at": now, "updated_at": now,
                   "_settings": settings, "_paths": {}}
            with self._lock:
                if self._closed:
                    raise PDFError("Dịch vụ đang đóng.")
                if request_id in self._requests:
                    previous_id, previous_hash = self._requests[request_id]
                    if previous_hash != fingerprint:
                        raise PDFError("Request ID đã được dùng cho PDF hoặc cấu hình khác.")
                    return self.status(previous_id)
                self._jobs[job_id] = job
                self._cancellations[job_id] = threading.Event()
                if request_id:
                    self._requests[request_id] = (job_id, fingerprint)
                self._queue.put(job_id)
                committed = True
                return self.status(job_id)
        finally:
            with self._lock:
                self._pending_submissions -= 1
            if not committed and directory.exists():
                self._remove_job_directory(directory)

    def status(self, job_id: str) -> dict:
        with self._lock:
            if job_id not in self._jobs:
                raise KeyError("Không tìm thấy công việc.")
            return {key: (list(value) if isinstance(value, list) else value)
                    for key, value in self._jobs[job_id].items() if not key.startswith("_")}

    def request_status(self, request_id: str) -> dict:
        with self._lock:
            return self.status(self._requests[str(uuid.UUID(request_id))][0])

    def list_jobs(self) -> list[dict]:
        with self._lock:
            return [self.status(job_id) for job_id in reversed(self._jobs)]

    def _update(self, job_id, **updates):
        with self._lock:
            job = self._jobs[job_id]
            if job["status"] == "cancelled":
                return
            job.update(updates, updated_at=time.time())

    def cancel(self, job_id: str) -> dict:
        with self._lock:
            job = self._jobs[job_id]
            if job["status"] not in TERMINAL:
                self._cancellations[job_id].set()
                job.update(status="cancelled", stage="Đã hủy", message="Đã hủy công việc.", updated_at=time.time())
                job["_settings"] = None
            return self.status(job_id)

    def download_path(self, job_id: str, kind="mono") -> Path:
        with self._lock:
            job = self._jobs[job_id]
            if job["status"] != "completed" or kind not in job["_paths"]:
                raise PDFError("Bản dịch chưa hoàn thành hoặc không có định dạng này.")
            path = Path(job["_paths"][kind]).resolve()
            if not path.is_relative_to(self.root / job_id) or not path.is_file():
                raise PDFError("Không tìm thấy PDF kết quả.")
            return path

    def _work(self):
        while True:
            job_id = self._queue.get()
            if job_id is None:
                return
            if self._cancellations[job_id].is_set():
                continue
            job = self._jobs[job_id]
            with self._lock:
                settings = job["_settings"]
            if settings is None or self._cancellations[job_id].is_set():
                continue
            directory = self.root / job_id
            output = directory / "output"
            output.mkdir(exist_ok=True)
            self._update(job_id, status="running", stage="Khởi động engine", message="Lần đầu cần tải model và font qua mạng.")
            def report(event):
                value = event.get("progress", 0)
                progress = float(value) if isinstance(value, (int, float)) and math.isfinite(value) else 0
                self._update(job_id, progress=min(99.9, max(job["progress"], progress)),
                             stage=event.get("stage", "Đang dịch"), message="Đang xử lý bố cục và dịch văn bản.")
            try:
                result = self._runner(directory / "input.pdf", output, settings, report, self._cancellations[job_id])
                if self._cancellations[job_id].is_set():
                    self._remove_output(job_id)
                    continue
                paths = {}
                for kind, raw in result.items():
                    path = Path(raw).resolve()
                    if kind not in {"mono", "dual"} or not path.is_relative_to(output) or not path.is_file():
                        raise PDFError("Engine trả về đường dẫn kết quả không hợp lệ.")
                    with open_document(path):
                        pass
                    paths[kind] = str(path)
                if "mono" not in paths:
                    raise PDFError("Engine không tạo PDF tiếng Việt.")
                self._update(job_id, status="completed", progress=100, stage="Hoàn thành",
                             message="Đã tạo bản dịch. Hãy kiểm tra bố cục, công thức và chú thích.",
                             outputs=list(paths), _paths=paths, _settings=None)
            except Exception as error:
                self._update(job_id, status="failed", stage="Thất bại", message="Không thể hoàn thành bản dịch.",
                             error=_safe_error(error, settings), _settings=None)
                self._remove_output(job_id)
            finally:
                # Keys never persist; closing the session removes its staged PDFs.
                with self._lock:
                    job["_settings"] = None

    def shutdown(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            for job_id in self._jobs:
                self.cancel(job_id)
            self._queue.put(None)
        self._thread.join(timeout=8)
        if not self._thread.is_alive():
            for job_id in self._jobs:
                self._remove_job_directory(self.root / job_id)
