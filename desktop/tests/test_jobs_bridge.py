import io
import json
import os
import threading
import time
import uuid

import pymupdf
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from scanpdf.services.bridge import BridgeServer, create_app
from scanpdf.services.jobs import JobManager, TranslationSettings, RETENTION_SECONDS, _upstream_settings
from scanpdf.services.pdf_ops import PDFError


def pdf_bytes(text="The document contains native English text."):
    with pymupdf.open() as document:
        document.new_page().insert_text((50, 80), text)
        return document.tobytes()


def completed_runner(source, output, settings, report, cancel):
    report({"progress": 42, "stage": "Translate Paragraphs"})
    path = output / "translated.pdf"
    path.write_bytes(pdf_bytes("Translated fixture output"))
    return {"mono": str(path)}


def wait_terminal(manager, job_id):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        status = manager.status(job_id)
        if status["status"] in {"completed", "cancelled", "failed"}:
            return status
        time.sleep(.01)
    pytest.fail("Job did not settle")


def test_status_progress_download_and_settings_never_leak(tmp_path):
    manager = JobManager(tmp_path / "jobs", runner=completed_runner)
    try:
        manager.set_default_settings(TranslationSettings(service="openai", api_key="PRIVATE-KEY", model="test-model"))
        job = manager.submit_bytes(pdf_bytes(), "../../native.pdf", TranslationSettings(service="server"))
        assert job["filename"] == "native.pdf"
        status = wait_terminal(manager, job["id"])
        assert status["status"] == "completed" and status["progress"] == 100
        assert status["outputs"] == ["mono"]
        assert "PRIVATE-KEY" not in json.dumps(manager.list_jobs())
        assert manager.download_path(job["id"]).read_bytes().startswith(b"%PDF")
    finally:
        manager.shutdown()
    assert not list((tmp_path / "jobs").iterdir())


def test_auth_raw_upload_idempotency_poll_download_and_conflict(tmp_path):
    manager = JobManager(tmp_path / "jobs", runner=completed_runner)
    token = "a" * 40
    try:
        client = TestClient(create_app(manager, token))
        assert client.get("/health").status_code == 401
        assert client.get("/health", headers={"X-Pair-Token": "wrong"}).status_code == 401
        assert client.get("/health", headers=[(b"X-Pair-Token", b"wrong-\xe9-token")]).status_code == 401
        headers = {"X-Pair-Token": token}
        health = client.get("/health", headers=headers).json()
        assert health["protocol_version"] == 1 and not health["scan_translation"]
        request_id = str(uuid.uuid4())
        headers.update({"Content-Type": "application/pdf", "X-Request-ID": request_id})
        upload = pdf_bytes()
        response = client.post("/jobs?filename=paper.pdf&service=google", headers=headers, content=upload)
        assert response.status_code == 202
        job_id = response.json()["id"]
        # Byte-identical retry with the same UUID produces exactly one job.
        retry = client.post("/jobs?filename=paper.pdf&service=google", headers=headers, content=upload)
        assert retry.status_code == 202 and retry.json()["id"] == job_id
        assert len(manager.list_jobs()) == 1
        assert client.get(f"/requests/{request_id}", headers=headers).json()["id"] == job_id
        conflict = client.post("/jobs?service=google", headers=headers, content=pdf_bytes("A different document text"))
        assert conflict.status_code == 422
        assert wait_terminal(manager, job_id)["status"] == "completed"
        download = client.get(f"/jobs/{job_id}/download", headers=headers)
        assert download.status_code == 200 and download.content.startswith(b"%PDF")
        assert client.get(f"/jobs/{job_id}/download?kind=../../input", headers=headers).status_code == 409
        assert client.get("/jobs/nonexistent", headers=headers).status_code == 404
        assert client.post("/jobs/", headers=headers, content=pdf_bytes(), follow_redirects=False).status_code == 404
        too_large = client.post("/jobs", headers={**headers, "Content-Length": "104857601"}, content=b"x")
        assert too_large.status_code == 413
    finally:
        manager.shutdown()


def test_running_and_queued_cancel_are_immediate_and_worker_finishes(tmp_path):
    started = threading.Event()
    stopped = threading.Event()
    def runner(source, output, settings, report, cancel):
        started.set()
        cancel.wait(5)
        stopped.set()
        return {}
    manager = JobManager(tmp_path / "jobs", runner=runner)
    try:
        first = manager.submit_bytes(pdf_bytes(), "one.pdf")
        assert started.wait(2)
        second = manager.submit_bytes(pdf_bytes(), "two.pdf")
        assert manager.cancel(second["id"])["status"] == "cancelled"
        assert manager.cancel(first["id"])["status"] == "cancelled"
        assert stopped.wait(2)
        with pytest.raises(PDFError):
            manager.download_path(first["id"])
    finally:
        manager.shutdown()


def test_scan_hidden_ocr_and_bad_password_rejected_without_job(tmp_path):
    stream = io.BytesIO()
    Image.new("RGB", (400, 600), "white").save(stream, format="PNG")
    with pymupdf.open() as document:
        page = document.new_page(width=400, height=600)
        page.insert_image(page.rect, stream=stream.getvalue())
        scan = document.tobytes()
        page.insert_text((20, 50), "An invisible OCR text layer", render_mode=3)
        hidden_ocr = document.tobytes()
        page.insert_text((30, 300), "Watermark")
        mixed_scan = document.tobytes()
    manager = JobManager(tmp_path / "jobs", runner=completed_runner)
    try:
        for data in (scan, hidden_ocr, mixed_scan, b"invalid PDF"):
            with pytest.raises(PDFError):
                manager.submit_bytes(data, "scan.pdf")
        assert not manager.list_jobs()
        assert not list((tmp_path / "jobs").iterdir())
    finally:
        manager.shutdown()


def test_errors_redact_secrets_and_untrusted_output_path_rejected(tmp_path):
    def failing(source, output, settings, report, cancel):
        raise RuntimeError("PRIVATE-KEY at https://example.org?key=PRIVATE-KEY")
    manager = JobManager(tmp_path / "jobs", runner=failing)
    try:
        job = manager.submit_bytes(pdf_bytes(), "paper.pdf", TranslationSettings(service="openai", api_key="PRIVATE-KEY", model="test"))
        result = wait_terminal(manager, job["id"])
        assert result["status"] == "failed" and "PRIVATE-KEY" not in result["error"]
    finally:
        manager.shutdown()
    outside = tmp_path / "outside.pdf"
    outside.write_bytes(pdf_bytes())
    manager = JobManager(tmp_path / "other-jobs", runner=lambda *args: {"mono": str(outside)})
    try:
        job = manager.submit_bytes(pdf_bytes(), "paper.pdf")
        assert wait_terminal(manager, job["id"])["status"] == "failed"
        assert outside.exists()
    finally:
        manager.shutdown()


def test_retention_only_removes_expired_uuid_directories(tmp_path):
    root = tmp_path / "jobs"
    root.mkdir()
    expired = root / str(uuid.uuid4())
    expired.mkdir()
    (expired / "input.pdf").write_bytes(pdf_bytes())
    old = time.time() - RETENTION_SECONDS - 1
    os.utime(expired, (old, old))
    keep = root / "user-folder"
    keep.mkdir()
    os.utime(keep, (old, old))
    fresh = root / str(uuid.uuid4())
    fresh.mkdir()
    manager = JobManager(root, runner=completed_runner)
    try:
        assert not expired.exists() and keep.exists() and fresh.exists()
        with pytest.raises(PDFError):
            manager._remove_job_directory(tmp_path)
    finally:
        manager.shutdown()


def test_pdf_preflight_does_not_block_status_or_cancellation(tmp_path, monkeypatch):
    import scanpdf.services.jobs as jobs
    entered = threading.Event()
    release = threading.Event()
    original = jobs.validate_translation_pdf
    def slow_validation(path, settings):
        entered.set()
        assert release.wait(3)
        original(path, settings)
    manager = JobManager(tmp_path / "jobs", runner=completed_runner)
    first = manager.submit_bytes(pdf_bytes(), "first.pdf")
    monkeypatch.setattr(jobs, "validate_translation_pdf", slow_validation)
    errors = []
    def submit():
        try:
            manager.submit_bytes(pdf_bytes(), "second.pdf")
        except Exception as error:
            errors.append(error)
    thread = threading.Thread(target=submit)
    try:
        thread.start()
        assert entered.wait(2)
        started = time.monotonic()
        assert manager.status(first["id"])["id"] == first["id"]
        manager.cancel(first["id"])
        assert time.monotonic() - started < .5
    finally:
        release.set()
        thread.join(4)
        manager.shutdown()
    assert not errors and not thread.is_alive()


def test_upstream_options_are_vi_no_scan_masking_and_custom_provider(tmp_path):
    pytest.importorskip("pdf2zh_next")
    settings = _upstream_settings(TranslationSettings(), tmp_path)
    settings.validate_settings()
    assert settings.translate_engine_settings.translate_engine_type == "Google"
    assert settings.translation.lang_in == "auto" and settings.translation.lang_out == "vi"
    assert not settings.pdf.ocr_workaround and not settings.pdf.auto_enable_ocr_workaround
    custom = _upstream_settings(TranslationSettings(service="openai", api_key="secret", model="custom-model", base_url="https://example.com/v1"), tmp_path)
    custom.validate_settings()
    assert custom.translate_engine_settings.openai_model == "custom-model"
    with pytest.raises(PDFError):
        TranslationSettings(service="bing", source="auto").validate()
