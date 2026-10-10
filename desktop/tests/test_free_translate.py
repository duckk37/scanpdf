import requests
import pytest

from scanpdf.services.free_translate import GoogleJSONTranslator, text_chunks, translated_text


def test_translated_segments_are_joined_and_invalid_payload_is_rejected():
    assert translated_text([[["Năng lượng ", "Energy"], ["và công thức", "and formula"]]]) == "Năng lượng và công thức"
    for payload in (None, {}, [], [[[]]], [[[None]]]):
        with pytest.raises(ValueError):
            translated_text(payload)


def test_large_paragraph_is_not_silently_truncated():
    text = "A long paragraph with formula {v1}. " * 500
    chunks = text_chunks(text)
    assert "".join(chunks) == text
    assert all(len(chunk) <= 4000 for chunk in chunks)
    assert sum(chunk.count("{v1}") for chunk in chunks) == text.count("{v1}")


def test_google_adapter_uses_auto_vi_and_http_timeout(monkeypatch):
    translator = object.__new__(GoogleJSONTranslator)
    translator.lang_in, translator.lang_out = "auto", "vi"
    calls = []
    class Response:
        def raise_for_status(self): pass
        def json(self): return [[["Năng lượng", "Energy"]]]
    def get(url, **kwargs):
        calls.append((url, kwargs))
        return Response()
    monkeypatch.setattr(requests, "get", get)
    assert translator._request("Energy") == "Năng lượng"
    assert calls[0][1]["params"]["sl"] == "auto"
    assert calls[0][1]["params"]["tl"] == "vi"
    assert calls[0][1]["timeout"] == (15, 45)


def test_rate_limit_is_reported_without_retrying(monkeypatch):
    translator = object.__new__(GoogleJSONTranslator)
    translator.lang_in, translator.lang_out = "auto", "vi"
    count = 0
    def get(*args, **kwargs):
        nonlocal count
        count += 1
        response = requests.Response()
        response.status_code = 429
        raise requests.HTTPError("429 Too Many Requests", response=response)
    monkeypatch.setattr(requests, "get", get)
    with pytest.raises(requests.HTTPError):
        translator._request("Energy")
    assert count == 1
