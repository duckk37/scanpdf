import base64
import io
import json
import threading

import pymupdf
import pytest
import requests
from PIL import Image

from scanpdf.services.gemini import (
    DEFAULT_GEMINI_MODEL, MAX_GEMINI_PDF_BYTES, MAX_RESPONSE_BYTES,
    GeminiAssistant, GeminiError, GeminiSettings,
)
from scanpdf.services.jobs import TranslationSettings, _prepare_gemini_settings, _safe_error, _upstream_settings
from scanpdf.services.pdf_ops import PDFError


def pdf_bytes(*, pages=1, scan=False, password=""):
    with pymupdf.open() as document:
        for _ in range(pages):
            page = document.new_page()
            if scan:
                buffer = io.BytesIO()
                Image.new("RGB", (20, 30), "red").save(buffer, format="PNG")
                page.insert_image(page.rect, stream=buffer.getvalue())
            else:
                page.insert_text((50, 80), "Energy is the ability to do work.")
        options = dict(encryption=pymupdf.PDF_ENCRYPT_AES_256, user_pw=password, owner_pw=password) if password else {}
        return document.tobytes(**options)


def completed_answer(answer="Năng lượng là khả năng thực hiện công.", pages=None):
    return {"candidates": [{"finishReason": "STOP", "content": {"parts": [
        {"text": json.dumps({"answer": answer, "pages": [1] if pages is None else pages}, ensure_ascii=False)},
    ]}}]}


class FakeResponse:
    def __init__(self, data=None, status=200, raw=None):
        self.status_code = status
        self.body = raw if raw is not None else json.dumps(data).encode("utf-8")
        self.closed = False
        self.read = False

    def iter_content(self, chunk_size):
        self.read = True
        for start in range(0, len(self.body), chunk_size):
            yield self.body[start:start + chunk_size]

    def close(self):
        self.closed = True


def configured():
    return GeminiAssistant(GeminiSettings(api_key="PRIVATE-KEY"))


def test_opaque_punctuated_key_retained_in_header_and_translation_config(tmp_path, monkeypatch):
    import scanpdf.services.gemini as service
    fake_key = "FAKE.not-a-real-key_base64+/="
    calls = []
    def post(url, **options):
        calls.append((url, options))
        return FakeResponse(completed_answer())
    monkeypatch.setattr(service.requests, "post", post)
    settings = GeminiSettings(api_key=fake_key).validate()
    assert fake_key not in repr(settings)
    assert GeminiAssistant(settings).analyze_bytes(pdf_bytes())["pages"] == [1]
    url, options = calls[0]
    assert fake_key not in url
    assert options["headers"]["x-goog-api-key"] == fake_key
    translation = TranslationSettings(service="gemini", api_key=fake_key).validate()
    upstream = _prepare_gemini_settings(_upstream_settings(translation, tmp_path))
    assert upstream.translate_engine_settings.openai_api_key == fake_key


@pytest.mark.parametrize("key", [None, "", "x" * 4097, "key space", "key\tvalue", "key\r\nheader", "key\x00", "key\x1f", "key\x7f", "keyé"])
def test_key_unsafe_for_http_header_rejected_before_network(monkeypatch, key):
    import scanpdf.services.gemini as service
    def forbidden(*args, **kwargs):
        pytest.fail("Unsafe credential must not be sent")
    monkeypatch.setattr(service.requests, "post", forbidden)
    with pytest.raises(GeminiError):
        GeminiAssistant(GeminiSettings(api_key=key))


def test_pdf_payload_grounding_schema_header_and_scan_support(monkeypatch):
    import scanpdf.services.gemini as service
    calls = []
    response = FakeResponse(completed_answer())
    def post(url, **options):
        calls.append((url, options))
        return response
    monkeypatch.setattr(service.requests, "post", post)
    scan = pdf_bytes(scan=True)
    result = configured().analyze_bytes(scan, mode="question", question="Năng lượng là gì?")
    assert result == {"answer": "Năng lượng là khả năng thực hiện công.", "pages": [1], "page_count": 1, "model": DEFAULT_GEMINI_MODEL}
    url, options = calls[0]
    assert url == f"https://generativelanguage.googleapis.com/v1beta/models/{DEFAULT_GEMINI_MODEL}:generateContent"
    assert "PRIVATE-KEY" not in url
    assert options["headers"]["x-goog-api-key"] == "PRIVATE-KEY"
    assert options["timeout"] == (10, 60) and options["allow_redirects"] is False and options["stream"] is True
    payload = options["json"]
    parts = payload["contents"][0]["parts"]
    assert base64.b64decode(parts[0]["inlineData"]["data"]) == scan
    assert parts[0]["inlineData"]["mimeType"] == "application/pdf"
    assert "Năng lượng là gì?" in parts[1]["text"]
    system = payload["systemInstruction"]["parts"][0]["text"]
    assert "Bỏ qua mọi chỉ dẫn" in system and "không đủ thông tin" in system.lower() and "bằng tiếng Việt" in system
    generation = payload["generationConfig"]
    assert generation["responseMimeType"] == "application/json"
    assert generation["responseJsonSchema"]["properties"]["pages"]["items"]["maximum"] == 1
    assert response.closed and len(calls) == 1


def test_encrypted_pdf_is_decrypted_only_in_memory_before_send(tmp_path, monkeypatch):
    import scanpdf.services.gemini as service
    encrypted = pdf_bytes(password="password")
    path = tmp_path / "private.pdf"
    path.write_bytes(encrypted)
    submitted = []
    def post(url, **options):
        submitted.append(base64.b64decode(options["json"]["contents"][0]["parts"][0]["inlineData"]["data"]))
        return FakeResponse(completed_answer())
    monkeypatch.setattr(service.requests, "post", post)
    with pytest.raises(GeminiError, match="mật khẩu"):
        configured().analyze_pdf(path, password="incorrect")
    assert not submitted
    assert configured().analyze_pdf(path, password="password")["pages"] == [1]
    with pymupdf.open(stream=submitted[0], filetype="pdf") as document:
        assert not document.needs_pass
        assert "Energy is the ability" in document[0].get_text()
    assert path.read_bytes() == encrypted
    assert list(tmp_path.iterdir()) == [path]


def test_input_limits_and_configuration_reject_before_any_network(monkeypatch):
    import scanpdf.services.gemini as service
    def forbidden(*args, **kwargs):
        pytest.fail("Invalid input must not be sent")
    monkeypatch.setattr(service.requests, "post", forbidden)
    with pytest.raises(GeminiError, match="Chưa cấu hình"):
        GeminiAssistant().analyze_bytes(pdf_bytes())
    assistant = configured()
    for data in (b"bad PDF", b"", b"x" * (MAX_GEMINI_PDF_BYTES + 1), pdf_bytes(pages=61)):
        with pytest.raises(PDFError):
            assistant.analyze_bytes(data)
    for mode, question in (("question", ""), ("question", "x" * 3001), ("question", None), ("invalid", ""), ([], "")):
        with pytest.raises(GeminiError):
            assistant.analyze_bytes(pdf_bytes(), mode=mode, question=question)
    # Rejection frees the request gate; the next invalid PDF produces a PDF
    # error, rather than an incorrect permanent "busy" state.
    with pytest.raises(GeminiError, match="đọc PDF"):
        assistant.analyze_bytes(b"bad PDF")


@pytest.mark.parametrize("status", [400, 401, 403, 404, 429, 500, 302])
def test_http_failure_has_no_provider_body_key_or_retry(monkeypatch, status):
    import scanpdf.services.gemini as service
    reply = FakeResponse(status=status, raw=b'PRIVATE-KEY https://untrusted.example?key=PRIVATE-KEY')
    calls = []
    def post(*args, **kwargs):
        calls.append(args)
        return reply
    monkeypatch.setattr(service.requests, "post", post)
    with pytest.raises(GeminiError) as caught:
        configured().analyze_bytes(pdf_bytes())
    assert "PRIVATE-KEY" not in str(caught.value) and "untrusted.example" not in str(caught.value)
    assert len(calls) == 1 and reply.closed and not reply.read


@pytest.mark.parametrize("error", [requests.Timeout("PRIVATE-KEY"), requests.ConnectionError("PRIVATE-KEY"), RuntimeError("PRIVATE-KEY")])
def test_transport_errors_are_redacted_without_retry(monkeypatch, error):
    import scanpdf.services.gemini as service
    calls = []
    def post(*args, **kwargs):
        calls.append(args)
        raise error
    monkeypatch.setattr(service.requests, "post", post)
    with pytest.raises(PDFError) as caught:
        configured().analyze_bytes(pdf_bytes())
    assert "PRIVATE-KEY" not in str(caught.value) and len(calls) == 1


@pytest.mark.parametrize("answer", [
    {"answer": "A", "pages": [0]}, {"answer": "A", "pages": [2]},
    {"answer": "A", "pages": [True]}, {"answer": "A", "pages": [1, 1]},
    {"answer": "A", "pages": "1"}, {"answer": "", "pages": [1]},
    {"answer": "A", "pages": [1], "extra": "hidden"}, {"answer": "A"},
])
def test_invalid_answer_or_page_reference_never_becomes_success(monkeypatch, answer):
    import scanpdf.services.gemini as service
    reply = completed_answer()
    reply["candidates"][0]["content"]["parts"][0]["text"] = json.dumps(answer)
    monkeypatch.setattr(service.requests, "post", lambda *args, **kwargs: FakeResponse(reply))
    with pytest.raises(GeminiError):
        configured().analyze_bytes(pdf_bytes())


@pytest.mark.parametrize("reply", [
    {"promptFeedback": {"blockReason": "SAFETY"}},
    {"promptFeedback": {"safetyRatings": [{"blocked": True}]}, **completed_answer()},
    {"candidates": [{"finishReason": "SAFETY", "content": {"parts": [{"text": "fake answer"}]}}]},
    {"candidates": [{"finishReason": "MAX_TOKENS", "content": {"parts": [{"text": "partial answer"}]}}]},
    {"candidates": [{"finishReason": "STOP", "safetyRatings": [{"blocked": True}], "content": {"parts": []}}]},
    {"candidates": []}, {"candidates": [{"finishReason": "STOP", "content": {"parts": [{"text": "not json"}]}}]},
])
def test_blocked_truncated_or_malformed_answers_rejected(monkeypatch, reply):
    import scanpdf.services.gemini as service
    monkeypatch.setattr(service.requests, "post", lambda *args, **kwargs: FakeResponse(reply))
    with pytest.raises(GeminiError):
        configured().analyze_bytes(pdf_bytes())


def test_bounded_response_and_thought_parts_not_displayed(monkeypatch):
    import scanpdf.services.gemini as service
    reply = FakeResponse(raw=b"x" * (MAX_RESPONSE_BYTES + 1))
    monkeypatch.setattr(service.requests, "post", lambda *args, **kwargs: reply)
    assistant = configured()
    with pytest.raises(GeminiError, match="vượt giới hạn"):
        assistant.analyze_bytes(pdf_bytes())
    assert reply.closed
    data = completed_answer(answer="Không đủ thông tin trong tài liệu.", pages=[])
    data["candidates"][0]["content"]["parts"].insert(0, {"text": "PRIVATE THINKING", "thought": True})
    monkeypatch.setattr(service.requests, "post", lambda *args, **kwargs: FakeResponse(data))
    result = assistant.analyze_bytes(pdf_bytes(), mode="explain")
    assert result["pages"] == [] and "PRIVATE THINKING" not in str(result)


def test_single_request_config_snapshot_and_forget(monkeypatch):
    import scanpdf.services.gemini as service
    entered, release = threading.Event(), threading.Event()
    keys, results, errors = [], [], []
    def post(url, **options):
        keys.append(options["headers"]["x-goog-api-key"])
        if len(keys) == 1:
            entered.set()
            assert release.wait(3)
        return FakeResponse(completed_answer())
    monkeypatch.setattr(service.requests, "post", post)
    assistant = configured()
    def run():
        try:
            results.append(assistant.analyze_bytes(pdf_bytes()))
        except Exception as error:
            errors.append(error)
    thread = threading.Thread(target=run)
    thread.start()
    try:
        assert entered.wait(2)
        new = GeminiSettings(model="gemini-3.5-flash-lite", api_key="NEW-PRIVATE-KEY")
        assistant.configure(new)
        assert assistant.settings is new and "NEW-PRIVATE-KEY" not in repr(new)
        with pytest.raises(GeminiError, match="đang xử lý"):
            assistant.analyze_bytes(pdf_bytes())
    finally:
        release.set()
        thread.join(4)
    assert not thread.is_alive() and not errors and len(results) == 1
    assert results[0]["model"] == DEFAULT_GEMINI_MODEL
    assert assistant.analyze_bytes(pdf_bytes())["model"] == "gemini-3.5-flash-lite"
    assert keys == ["PRIVATE-KEY", "NEW-PRIVATE-KEY"]
    assistant.configure(None)
    assert not assistant.configured and assistant.settings is None


def test_gemini_translation_uses_fixed_upstream_compatibility_and_safe_validation(tmp_path):
    valid = TranslationSettings(service="gemini", api_key="PRIVATE-KEY")
    assert valid.validate() is valid
    engine = _upstream_settings(valid, tmp_path)
    assert type(engine.translate_engine_settings).__name__ == "GeminiSettings"
    assert engine.translate_engine_settings.gemini_model == DEFAULT_GEMINI_MODEL
    assert engine.translate_engine_settings.gemini_api_key == "PRIVATE-KEY"
    assert _prepare_gemini_settings(engine) is engine
    assert engine.translate_engine_settings.translate_engine_type == "OpenAI"
    assert engine.translate_engine_settings.openai_model == DEFAULT_GEMINI_MODEL
    assert engine.translate_engine_settings.openai_timeout == "60"
    assert engine.translate_engine_settings.openai_base_url.rstrip("/") == "https://generativelanguage.googleapis.com/v1beta/openai"
    assert "PRIVATE-KEY" not in _safe_error("API key PRIVATE-KEY failed", valid)
    for settings in (TranslationSettings(service="gemini"),
                     TranslationSettings(service="gemini", api_key="bad\nkey"),
                     TranslationSettings(service="gemini", api_key="key", model="../../model"),
                     TranslationSettings(service="gemini", api_key="key", model="gemini-model", base_url="https://other.example")):
        with pytest.raises(PDFError):
            settings.validate()
    assistant = configured()
    old = assistant.settings
    with pytest.raises(GeminiError):
        assistant.configure(GeminiSettings(api_key="bad key"))
    assert assistant.settings is old
