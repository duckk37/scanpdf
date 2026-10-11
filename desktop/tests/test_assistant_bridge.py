import base64
import json
from types import SimpleNamespace

import pymupdf
from fastapi.testclient import TestClient

from scanpdf.services.bridge import ASSISTANT_UPLOAD_BYTES, create_app
from scanpdf.services.jobs import JobManager


class Assistant:
    settings = SimpleNamespace(api_key="fake-private-key")

    def __init__(self):
        self.calls = []

    def analyze_pdf(self, path, mode, question):
        self.calls.append((path.read_bytes(), mode, question, path))
        return {"answer": "Năng lượng được mô tả trong tài liệu.", "pages": [1], "page_count": 1, "model": "gemini-3.8-flash"}


def pdf_bytes():
    with pymupdf.open() as doc:
        page = doc.new_page()
        page.insert_text((50, 90), "Energy and motion")
        return doc.tobytes()


def options(value):
    return base64.b64encode(json.dumps(value, ensure_ascii=False).encode()).decode()


def test_assistant_route_auth_upload_options_no_secrets_and_scoped_cleanup(tmp_path):
    manager = JobManager(tmp_path / "jobs")
    assistant = Assistant()
    token = "long-random-test-token-for-bridge"
    try:
        client = TestClient(create_app(manager, token, assistant))
        data = pdf_bytes()
        assert client.post("/assistant", content=data).status_code == 401
        headers = {"X-Pair-Token": token, "Content-Type": "application/pdf",
                   "X-Assistant-Options": options({"mode": "question", "question": "Năng lượng là gì?"})}
        health = client.get("/health", headers={"X-Pair-Token": token})
        assert health.json()["assistant_ready"]
        assert "fake-private-key" not in health.text
        response = client.post("/assistant", content=data, headers=headers)
        assert response.status_code == 200
        assert response.headers["Cache-Control"] == "no-store"
        assert response.json()["pages"] == [1]
        assert assistant.calls[0][:3] == (data, "question", "Năng lượng là gì?")
        assert not assistant.calls[0][3].exists()
        assert "fake-private-key" not in response.text
        assert client.post("/assistant", content=data, headers={**headers, "X-Assistant-Options": "invalid!!!"}).status_code == 422
        assert client.post("/assistant", content=data, headers={**headers, "X-Assistant-Options": options({"mode": "summary", "api_key": "injected"})}).status_code == 422
        assert client.post("/assistant", content=data, headers={**headers, "Content-Type": "text/plain"}).status_code == 415
        assert client.post("/assistant", content=data, headers={**headers, "Content-Length": str(ASSISTANT_UPLOAD_BYTES + 1)}).status_code == 413
        assert len(assistant.calls) == 1
    finally:
        manager.shutdown()


def test_assistant_requires_configured_pc_and_keeps_old_health_compatible(tmp_path):
    manager = JobManager(tmp_path / "jobs")
    token = "long-random-test-token-for-bridge"
    try:
        client = TestClient(create_app(manager, token))
        headers = {"X-Pair-Token": token}
        health = client.get("/health", headers=headers).json()
        assert health["protocol_version"] == 1 and not health["assistant_ready"]
        assert client.post("/assistant", content=pdf_bytes(), headers=headers).status_code == 503
    finally:
        manager.shutdown()
