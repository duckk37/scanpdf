"""A bounded Google JSON adapter for the PDF engine's translator interface.

This anonymous endpoint can impose quotas or change. Bing and a user-supplied
API remain available. No Google credentials are collected by ScanPDF.
"""
from __future__ import annotations

import re

import requests
from pdf2zh_next.translator.base_translator import BaseTranslator
from tenacity import retry, retry_if_exception, stop_after_attempt, wait_exponential


def _transient(error: BaseException) -> bool:
    if isinstance(error, (requests.Timeout, requests.ConnectionError)):
        return True
    return isinstance(error, requests.HTTPError) and error.response is not None and error.response.status_code >= 500


def text_chunks(text: str, limit: int = 4000) -> list[str]:
    result = []
    while len(text) > limit:
        cut = max(text.rfind(" ", 0, limit + 1), text.rfind("\n", 0, limit + 1))
        if cut <= 0:
            cut = limit
        result.append(text[:cut])
        text = text[cut:]
    if text:
        result.append(text)
    return result


def translated_text(payload) -> str:
    if not isinstance(payload, list) or not payload or not isinstance(payload[0], list):
        raise ValueError("Dịch vụ Google trả về dữ liệu không hợp lệ.")
    pieces = []
    for segment in payload[0]:
        if not isinstance(segment, list) or not segment or not isinstance(segment[0], str):
            raise ValueError("Dịch vụ Google trả về đoạn dịch không hợp lệ.")
        pieces.append(segment[0])
    text = "".join(pieces)
    if not text.strip():
        raise ValueError("Dịch vụ Google không trả về bản dịch.")
    return re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)


class GoogleJSONTranslator(BaseTranslator):
    name = "scanpdf-google"
    lang_map = {"zh": "zh-CN"}
    model = "public-json"
    endpoint = "https://translate.googleapis.com/translate_a/single"

    @retry(retry=retry_if_exception(_transient), stop=stop_after_attempt(3),
           wait=wait_exponential(multiplier=1, min=1, max=4), reraise=True)
    def _request(self, text: str) -> str:
        response = requests.get(self.endpoint, params={
            "client": "gtx", "sl": self.lang_in, "tl": self.lang_out,
            "dt": "t", "q": text,
        }, timeout=(15, 45))
        response.raise_for_status()
        return translated_text(response.json())

    def do_translate(self, text, rate_limit_params=None):
        pieces = []
        for index, chunk in enumerate(text_chunks(text)):
            if index:
                self.rate_limiter.wait(rate_limit_params)
            pieces.append(self._request(chunk))
        return " ".join(pieces)


def install_google_adapter() -> None:
    # Only the isolated translation worker calls this. Upstream's factory keeps
    # its rate limiting, cache and health check, using our translator class.
    from pdf2zh_next.translator.translator_impl import google
    google.GoogleTranslator = GoogleJSONTranslator
