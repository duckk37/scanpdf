"""Versioned, token-authenticated LAN bridge. Independent of the Qt GUI."""
from __future__ import annotations

import json
import secrets
import socket
import threading
import time
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool
import uvicorn

from .jobs import JobManager, MAX_UPLOAD_BYTES, TranslationSettings
from .pdf_ops import PDFError


def create_app(manager: JobManager, token: str) -> FastAPI:
    if len(token) < 24:
        raise ValueError("Mã ghép nối cần ít nhất 24 ký tự ngẫu nhiên.")

    async def authenticate(x_pair_token: str | None = Header(default=None)):
        if x_pair_token is None or not secrets.compare_digest(x_pair_token.encode("utf-8"), token.encode("utf-8")):
            raise HTTPException(401, "Mã ghép nối không đúng.")

    app = FastAPI(title="ScanPDF LAN Bridge", docs_url=None, redoc_url=None,
                  openapi_url=None, dependencies=[Depends(authenticate)])
    app.router.redirect_slashes = False

    @app.get("/health")
    async def health():
        return {"protocol_version": 1, "app": "ScanPDF", "engine": "pdf2zh-next/BabelDOC",
                "engine_ready": manager.engine_ready, "provider": manager.default_settings.service,
                "target_language": "vi", "scan_translation": False,
                "max_upload_bytes": MAX_UPLOAD_BYTES}

    @app.post("/jobs", status_code=202)
    async def submit(request: Request, filename: str = "document.pdf", service: str = "server",
                     source: str = "auto", target: str = "vi",
                     x_translation_settings: str | None = Header(default=None),
                     x_request_id: str | None = Header(default=None)):
        content_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        if content_type not in {"application/pdf", "application/octet-stream"}:
            raise HTTPException(415, "Gửi nội dung PDF với Content-Type: application/pdf.")
        try:
            content_length = int(request.headers.get("content-length", "0"))
            if content_length < 0:
                raise ValueError()
        except ValueError:
            raise HTTPException(400, "Content-Length không hợp lệ.")
        if content_length > MAX_UPLOAD_BYTES:
            raise HTTPException(413, "PDF vượt quá giới hạn 100 MB.")
        data = bytearray()
        async for chunk in request.stream():
            if len(data) + len(chunk) > MAX_UPLOAD_BYTES:
                raise HTTPException(413, "PDF vượt quá giới hạn 100 MB.")
            data.extend(chunk)
        try:
            raw = json.loads(x_translation_settings) if x_translation_settings else {}
            if not isinstance(raw, dict):
                raise ValueError("Cấu hình dịch phải là JSON object.")
            options = {"service": service, "source": source, "target": target, **raw}
            settings = TranslationSettings(**options)
            return await run_in_threadpool(manager.submit_bytes, bytes(data), filename, settings,
                                           request_id=x_request_id)
        except (ValueError, TypeError, PDFError) as error:
            # Validation errors never contain the API key or settings dictionary.
            detail = str(error) if isinstance(error, PDFError) else "Cấu hình dịch hoặc Request ID không hợp lệ."
            raise HTTPException(422, detail)

    @app.get("/jobs/{job_id}")
    async def status(job_id: str):
        try:
            return manager.status(job_id)
        except KeyError:
            raise HTTPException(404, "Không tìm thấy công việc.")

    @app.get("/requests/{request_id}")
    async def request_status(request_id: str):
        try:
            return manager.request_status(request_id)
        except (KeyError, ValueError):
            raise HTTPException(404, "Chưa tìm thấy yêu cầu này.")

    @app.delete("/jobs/{job_id}")
    async def cancel(job_id: str):
        try:
            return manager.cancel(job_id)
        except KeyError:
            raise HTTPException(404, "Không tìm thấy công việc.")

    @app.get("/jobs/{job_id}/download")
    async def download(job_id: str, kind: str = "mono"):
        try:
            path = manager.download_path(job_id, kind)
            original = manager.status(job_id)["filename"]
            filename = Path(original).stem + (".vi.pdf" if kind == "mono" else ".song-ngu.pdf")
            return FileResponse(path, media_type="application/pdf", filename=filename,
                                headers={"Cache-Control": "no-store"})
        except KeyError:
            raise HTTPException(404, "Không tìm thấy công việc.")
        except PDFError as error:
            raise HTTPException(409, str(error))

    return app


class BridgeServer:
    def __init__(self, manager: JobManager, token: str, host: str = "0.0.0.0", port: int = 8765):
        if not 1 <= port <= 65535:
            raise ValueError("Cổng mạng không hợp lệ.")
        self.manager, self.token, self.host, self.port = manager, token, host, port
        self.app = create_app(manager, token)
        self._server = None
        self._thread = None
        self._socket = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        # Bind synchronously so the GUI can report firewall/port conflicts accurately.
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            listener.bind((self.host, self.port))
            listener.listen(16)
            configuration = uvicorn.Config(self.app, host=self.host, port=self.port,
                                           log_level="warning", access_log=False, log_config=None)
            self._server = uvicorn.Server(configuration)
            self._socket = listener
            self._thread = threading.Thread(target=self._server.run, kwargs={"sockets": [listener]},
                                            name="scanpdf-lan", daemon=True)
            self._thread.start()
            deadline = time.monotonic() + 5
            while not self._server.started and self._thread.is_alive() and time.monotonic() < deadline:
                time.sleep(.03)
            if not self._server.started:
                self.stop()
                raise RuntimeError("Không thể khởi động dịch vụ Wi-Fi.")
        except Exception:
            listener.close()
            raise

    def stop(self) -> None:
        if self._server:
            self._server.should_exit = True
        if self._thread:
            self._thread.join(timeout=5)
            if self._thread.is_alive() and self._server:
                self._server.force_exit = True
                self._thread.join(timeout=2)
        if self._socket:
            self._socket.close()
        self._thread = self._server = self._socket = None
