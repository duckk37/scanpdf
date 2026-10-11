"""Opt-in Gemini PDF analysis; configuration stays in memory, never in a PDF.

This is separate from layout translation: Gemini reads the original PDF,
including scans, and returns a grounded Vietnamese answer with page references.
The caller obtains user consent before calling either analysis entry point.
"""
from __future__ import annotations

import base64
import json
import re
import threading
from dataclasses import dataclass, field
from pathlib import Path

import pymupdf
import requests

from .pdf_ops import PDFError
from .assistant_prompts import build_assistant_prompts

DEFAULT_GEMINI_MODEL = "gemini-3.8-flash"
MAX_GEMINI_PDF_BYTES = 10 * 1024 * 1024
MAX_GEMINI_PAGES = 60
MAX_QUESTION_CHARS = 3000
MAX_ANSWER_CHARS = 18000
MAX_RESPONSE_BYTES = 256 * 1024


class GeminiError(PDFError):
    """A safe, user-facing error without provider response bodies or secrets."""


@dataclass(frozen=True)
class GeminiSettings:
    model: str = DEFAULT_GEMINI_MODEL
    api_key: str | None = field(default=None, repr=False)

    def validate(self) -> "GeminiSettings":
        if not isinstance(self.model, str) or not re.fullmatch(r"gemini-[A-Za-z0-9][A-Za-z0-9._-]{0,119}", self.model):
            raise GeminiError("Tên model Gemini không hợp lệ. Dùng tên bắt đầu bằng gemini-.")
        # Credentials are opaque: Google may issue keys with punctuation.
        # Reject whitespace/control characters unsafe for HTTP headers, but
        # leave actual key validity and permissions to the provider.
        if not isinstance(self.api_key, str) or not self.api_key or len(self.api_key) > 4096 or not re.fullmatch(r"[\x21-\x7e]+", self.api_key):
            raise GeminiError("Nhập API key Gemini trong cài đặt trên PC. Key không được chứa khoảng trắng, xuống dòng hoặc ký tự điều khiển.")
        return self


def _read_pdf(data: bytes, password: str) -> tuple[bytes, int]:
    if not isinstance(data, bytes) or not data or len(data) > MAX_GEMINI_PDF_BYTES:
        raise GeminiError("Gemini nhận PDF tối đa 10 MB. Hãy tách hoặc nén PDF trước.")
    try:
        with pymupdf.open(stream=data, filetype="pdf") as document:
            if not document.is_pdf or not 1 <= len(document) <= MAX_GEMINI_PAGES:
                raise GeminiError("Gemini nhận PDF có từ 1 đến 60 trang. Hãy tách PDF trước.")
            # Query only BEFORE authentication: MuPDF 1.25.2 clears its key
            # when needs_pass invokes empty-password authentication again.
            protected = bool(document.needs_pass)
            if protected:
                if not document.authenticate(password):
                    raise GeminiError("PDF có mật khẩu. Hãy nhập mật khẩu đúng.")
                data = document.tobytes(encryption=pymupdf.PDF_ENCRYPT_NONE)
            count = len(document)
    except GeminiError:
        raise
    except Exception:
        raise GeminiError("Không thể đọc PDF. Tệp có thể đã bị hỏng.") from None
    if len(data) > MAX_GEMINI_PDF_BYTES:
        raise GeminiError("PDF sau khi mở khóa vượt 10 MB. Hãy tách hoặc nén PDF trước.")
    return data, count


def _request_payload(data: bytes, count: int, mode: str, question: str) -> dict:
    system, task = build_assistant_prompts(count, mode, question)
    return {
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": [{"role": "user", "parts": [
            {"inlineData": {"mimeType": "application/pdf", "data": base64.b64encode(data).decode("ascii")}},
            {"text": task},
        ]}],
        "generationConfig": {
            "candidateCount": 1, "maxOutputTokens": 4096,
            "responseMimeType": "application/json",
            "responseJsonSchema": {
                "type": "object", "additionalProperties": False, "required": ["answer", "pages"],
                "properties": {
                    "answer": {"type": "string"},
                    "pages": {"type": "array", "items": {"type": "integer", "minimum": 1, "maximum": count}},
                },
            },
        },
    }


def _validated_answer(response: dict, count: int) -> dict:
    invalid = "Gemini trả kết quả không hợp lệ. Hãy thử lại với yêu cầu ngắn hơn."
    if not isinstance(response, dict):
        raise GeminiError(invalid)
    feedback = response.get("promptFeedback", {})
    if not isinstance(feedback, dict):
        raise GeminiError(invalid)
    prompt_ratings = feedback.get("safetyRatings", [])
    if not isinstance(prompt_ratings, list) or any(not isinstance(r, dict) for r in prompt_ratings):
        raise GeminiError(invalid)
    if feedback.get("blockReason") not in (None, "", "BLOCK_REASON_UNSPECIFIED") or any(r.get("blocked") for r in prompt_ratings):
        raise GeminiError("Gemini không thể xử lý yêu cầu này theo bộ lọc nội dung của Google.")
    candidates = response.get("candidates")
    if not isinstance(candidates, list) or len(candidates) != 1 or not isinstance(candidates[0], dict):
        raise GeminiError(invalid)
    candidate = candidates[0]
    ratings = candidate.get("safetyRatings", [])
    if not isinstance(ratings, list) or any(not isinstance(r, dict) for r in ratings):
        raise GeminiError(invalid)
    if candidate.get("finishReason") in {"SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "RECITATION", "SPII"} or any(r.get("blocked") for r in ratings):
        raise GeminiError("Gemini không thể trả lời yêu cầu này theo bộ lọc nội dung của Google.")
    if candidate.get("finishReason") != "STOP":
        raise GeminiError("Gemini chưa tạo câu trả lời đầy đủ. Hãy thử yêu cầu ngắn hơn hoặc tách PDF.")
    content = candidate.get("content", {})
    if not isinstance(content, dict) or not isinstance(content.get("parts"), list):
        raise GeminiError(invalid)
    text_parts = []
    for part in content["parts"]:
        if not isinstance(part, dict):
            raise GeminiError(invalid)
        # Thinking models may include internal thought parts; never present them.
        if part.get("thought") is True:
            continue
        if set(part) - {"text", "thought", "thoughtSignature"} or not isinstance(part.get("text"), str):
            raise GeminiError(invalid)
        text_parts.append(part["text"])
    try:
        answer = json.loads("".join(text_parts))
    except (ValueError, TypeError):
        raise GeminiError(invalid) from None
    if not isinstance(answer, dict) or set(answer) != {"answer", "pages"}:
        raise GeminiError(invalid)
    text, pages = answer["answer"], answer["pages"]
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_ANSWER_CHARS:
        raise GeminiError(invalid)
    if not isinstance(pages, list) or len(pages) > count or any(type(p) is not int or not 1 <= p <= count for p in pages) or len(set(pages)) != len(pages):
        raise GeminiError("Gemini trả tham chiếu trang không hợp lệ. Hãy thử lại; kết quả chưa được hiển thị.")
    return {"answer": text.strip(), "pages": pages}


class GeminiAssistant:
    def __init__(self, settings: GeminiSettings | None = None):
        self._configuration_lock = threading.Lock()
        self._request_gate = threading.BoundedSemaphore(1)
        self._settings = None
        self.configure(settings)

    @property
    def settings(self) -> GeminiSettings | None:
        with self._configuration_lock:
            return self._settings

    @property
    def configured(self) -> bool:
        return self.settings is not None

    def configure(self, settings: GeminiSettings | None) -> None:
        if settings is not None:
            if not isinstance(settings, GeminiSettings):
                raise GeminiError("Cấu hình Gemini không hợp lệ.")
            settings.validate()
        with self._configuration_lock:
            self._settings = settings

    def analyze_pdf(self, path: str | Path, mode: str = "summary", question: str = "", password: str = "") -> dict:
        try:
            with Path(path).open("rb") as source:
                data = source.read(MAX_GEMINI_PDF_BYTES + 1)
        except (OSError, TypeError, ValueError):
            raise GeminiError("Không thể đọc tệp PDF đã chọn.") from None
        return self.analyze_bytes(data, mode=mode, question=question, password=password)

    def analyze_bytes(self, data: bytes, mode: str = "summary", question: str = "", password: str = "") -> dict:
        settings = self.settings
        if settings is None:
            raise GeminiError("Chưa cấu hình Gemini. Nhập API key trong cài đặt trên PC.")
        if not isinstance(mode, str) or mode not in {"summary", "question", "explain"}:
            raise GeminiError("Chọn tóm tắt, hỏi đáp hoặc giải thích PDF.")
        if not isinstance(question, str) or len(question) > MAX_QUESTION_CHARS or (mode == "question" and not question.strip()):
            raise GeminiError("Nhập câu hỏi từ 1 đến 3000 ký tự.")
        if not self._request_gate.acquire(blocking=False):
            raise GeminiError("Gemini đang xử lý một yêu cầu. Hãy đợi kết quả trước khi gửi tiếp.")
        try:
            data, count = _read_pdf(data, password)
            payload = _request_payload(data, count, mode, question.strip())
            endpoint = f"https://generativelanguage.googleapis.com/v1beta/models/{settings.model}:generateContent"
            try:
                # No retries or redirects: a submitted request can incur API charges.
                response = requests.post(endpoint, json=payload,
                                         headers={"x-goog-api-key": settings.api_key, "Content-Type": "application/json"},
                                         timeout=(10, 60), allow_redirects=False, stream=True)
                try:
                    if response.status_code != 200:
                        messages = {
                            400: "Gemini không chấp nhận yêu cầu. Kiểm tra API key, model và tệp PDF.",
                            401: "API key Gemini không hợp lệ.",
                            403: "API key Gemini chưa có quyền truy cập model đã chọn.",
                            404: "Không tìm thấy model Gemini đã chọn. Kiểm tra tên model.",
                            429: "Gemini đã hết hạn mức hoặc đang giới hạn truy cập. Kiểm tra hạn mức trong Google AI Studio.",
                        }
                        raise GeminiError(messages.get(response.status_code, "Không thể kết nối dịch vụ Gemini. Hãy thử lại sau."))
                    body = bytearray()
                    for chunk in response.iter_content(chunk_size=8192):
                        if len(body) + len(chunk) > MAX_RESPONSE_BYTES:
                            raise GeminiError("Phản hồi Gemini vượt giới hạn an toàn. Hãy dùng yêu cầu ngắn hơn.")
                        body.extend(chunk)
                finally:
                    response.close()
            except requests.Timeout:
                raise GeminiError("Gemini phản hồi quá lâu. Hãy thử PDF nhỏ hơn hoặc thử lại sau.") from None
            except requests.RequestException:
                raise GeminiError("Không thể kết nối Gemini. Kiểm tra mạng và thử lại sau.") from None
            try:
                result = _validated_answer(json.loads(body), count)
            except (ValueError, UnicodeError) as error:
                if isinstance(error, GeminiError):
                    raise
                raise GeminiError("Gemini trả dữ liệu không đọc được. Hãy thử lại sau.") from None
            return {**result, "page_count": count, "model": settings.model}
        except GeminiError:
            raise
        except Exception:
            # Provider / PDF parser internals may include headers, file paths
            # or raw response content in their exception. Never expose them.
            raise GeminiError("Không thể hoàn thành phân tích Gemini. Hãy kiểm tra tệp và thử lại sau.") from None
        finally:
            self._request_gate.release()
