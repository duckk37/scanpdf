"""Network-free checks of the frozen executable's spawned engine worker."""
from __future__ import annotations

import multiprocessing
import json
import re
import shutil
import tempfile
import time
from pathlib import Path


def _verify_pdf_search() -> None:
    """Exercise the real font filter without downloading a font or model."""
    import io
    import pymupdf
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from babeldoc.format.pdf.document_il.backend import pdf_creater
    from .services.jobs import _install_pdf_space_mapping_fix

    phrase = "Năng lượng có thể thực hiện công"
    characters = sorted(set(phrase))
    order = [".notdef", "dummy1", "dummy2", "dummy3", "space"]
    order += [f"uni{ord(char):04X}" for char in characters if char != " "]
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder(order)
    glyphs = {}
    for name in order:
        pen = TTGlyphPen(None)
        if name != "space":
            pen.moveTo((50, 0))
            pen.lineTo((450, 0))
            pen.lineTo((450, 700))
            pen.lineTo((50, 700))
            pen.closePath()
        glyphs[name] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({name: (300 if name == "space" else 550, 0) for name in order})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupCharacterMap({ord(char): "space" if char == " " else f"uni{ord(char):04X}"
                               for char in characters})
    builder.setupNameTable({"familyName": "ScanPDF Frozen Search", "styleName": "Regular",
                           "uniqueFontIdentifier": "ScanPDFFrozenSearch-Regular",
                           "fullName": "ScanPDF Frozen Search Regular",
                           "psName": "ScanPDFFrozenSearch-Regular"})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    builder.setupMaxp()
    font = io.BytesIO()
    builder.save(font)
    with pymupdf.open() as document:
        page = document.new_page(width=400, height=200)
        font_xref = page.insert_font(fontname="FrozenSearch.ttf", fontbuffer=font.getvalue())
        page.insert_text((30, 70), phrase, fontname="FrozenSearch.ttf", fontsize=13)
        before = page.get_pixmap().samples
        _install_pdf_space_mapping_fix()
        pdf_creater.reproduce_one_font(document, font_xref)
        with pymupdf.open(stream=document.tobytes(), filetype="pdf") as persisted:
            if phrase not in persisted[0].get_text() or not persisted[0].search_for("Năng lượng"):
                raise RuntimeError("The packaged PDF engine did not preserve searchable Vietnamese spaces.")
            if persisted[0].get_pixmap().samples != before:
                raise RuntimeError("PDF space mapping changed the rendered document.")


def _check_child(connection) -> None:
    try:
        import onnxruntime
        import pdf2zh_next.high_level
        import pymupdf
        from types import SimpleNamespace
        from unittest.mock import patch
        from .services.jobs import TranslationSettings, _upstream_settings
        from .services.gemini import GeminiAssistant, GeminiSettings
        _verify_pdf_search()
        with tempfile.TemporaryDirectory(prefix="scanpdf-worker-check-") as directory:
            configuration = _upstream_settings(TranslationSettings(source="en"), Path(directory))
            fake_key = "scanpdf-offline-test-key-not-a-real-credential"
            gemini_settings = GeminiSettings(api_key=fake_key).validate()
            assistant = GeminiAssistant(gemini_settings)
            if not assistant.configured or assistant.settings.model != gemini_settings.model:
                raise RuntimeError("The packaged Gemini assistant could not retain its configuration.")
            if fake_key in repr(gemini_settings):
                raise RuntimeError("Gemini settings exposed their API key in a diagnostic representation.")
            with pymupdf.open() as fixture:
                fixture.new_page().insert_text((40, 70), "Energy is the ability to do work.")
                data = fixture.tobytes()
            answer = "Năng lượng là khả năng thực hiện công."
            body = json.dumps({"candidates": [{"finishReason": "STOP", "content": {"parts": [
                {"text": json.dumps({"answer": answer, "pages": [1]}, ensure_ascii=False)}
            ]}}]}).encode("utf-8")
            response = SimpleNamespace(status_code=200, iter_content=lambda chunk_size: iter([body]), close=lambda: None)
            with patch("scanpdf.services.gemini.requests.post", return_value=response) as transport:
                result = assistant.analyze_bytes(data)
            if result != {"answer": answer, "pages": [1], "page_count": 1, "model": gemini_settings.model}:
                raise RuntimeError("The packaged Gemini assistant could not parse its offline transport response.")
            if transport.call_count != 1 or transport.call_args.kwargs["headers"]["x-goog-api-key"] != fake_key:
                raise RuntimeError("The packaged Gemini assistant did not use the expected offline transport.")
            gemini = _upstream_settings(TranslationSettings(service="gemini", source="en",
                                       api_key=fake_key, model=gemini_settings.model).validate(), Path(directory))
            gemini.validate_settings()
            engine = gemini.translate_engine_settings
            if (engine.translate_engine_type != "OpenAI" or engine.openai_model != gemini_settings.model
                    or engine.openai_base_url.rstrip("/") != "https://generativelanguage.googleapis.com/v1beta/openai"):
                raise RuntimeError("The packaged Gemini translation configuration is incompatible with the engine.")
            assistant.configure(None)
            if assistant.configured:
                raise RuntimeError("The packaged Gemini assistant did not clear its configuration.")
            connection.send({"ok": True, "provider": configuration.translate_engine_settings.translate_engine_type,
                             "language": configuration.translation.lang_out,
                             "pdf_search": "passed",
                             "gemini_config": "passed",
                             "gemini_mock_transport": "passed",
                             "onnxruntime": onnxruntime.__version__})
    except Exception as error:
        connection.send({"ok": False, "error": f"{type(error).__name__}: {error}"})
    finally:
        connection.close()


def verify_spawned_engine(timeout: float = 90) -> dict:
    context = multiprocessing.get_context("spawn")
    receiver, sender = context.Pipe(duplex=False)
    process = context.Process(target=_check_child, args=(sender,), name="scanpdf-package-check")
    process.start()
    sender.close()
    try:
        if not receiver.poll(timeout):
            raise RuntimeError("The packaged engine worker did not respond before the timeout.")
        result = receiver.recv()
        process.join(timeout=10)
        if process.exitcode != 0 or not result.get("ok"):
            raise RuntimeError(result.get("error", f"Engine worker exited with {process.exitcode}."))
        if result["provider"] != "Google" or result["language"] != "vi":
            raise RuntimeError("Engine worker configuration roundtrip failed.")
        if result.get("pdf_search") != "passed":
            raise RuntimeError("Packaged PDF search regression check failed.")
        if result.get("gemini_config") != "passed":
            raise RuntimeError("Packaged Gemini configuration check failed.")
        if result.get("gemini_mock_transport") != "passed":
            raise RuntimeError("Packaged Gemini mock transport check failed.")
        return result
    finally:
        receiver.close()
        if process.is_alive():
            process.terminate()
            process.join(timeout=10)
        process.close()


def run_translation_check(input_path: Path, output_dir: Path, timeout: float = 900) -> int:
    """Optional real-provider QA; write progress/results for a windowed EXE."""
    import pymupdf
    from .services.jobs import JobManager, TranslationSettings
    input_path, output_dir = Path(input_path).resolve(), Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest = output_dir / "translation-check.json"

    def write(value: dict) -> None:
        temporary = manifest.with_suffix(".tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary.replace(manifest)

    with tempfile.TemporaryDirectory(prefix="scanpdf-live-check-") as directory:
        manager = JobManager(Path(directory))
        try:
            settings = TranslationSettings(service="google", source="auto", target="vi")
            job = manager.submit_bytes(input_path.read_bytes(), input_path.name, settings)
            started = time.monotonic()
            while time.monotonic() - started < timeout:
                state = manager.status(job["id"])
                write(state)
                if state["status"] in {"failed", "cancelled"}:
                    return 2
                if state["status"] == "completed":
                    outputs = {}
                    for kind in ("mono", "dual"):
                        source = manager.download_path(job["id"], kind)
                        destination = output_dir / f"translation-check-{kind}.pdf"
                        shutil.copyfile(source, destination)
                        with pymupdf.open(destination) as pdf:
                            text = "\n".join(page.get_text() for page in pdf)
                            if not text.strip():
                                raise RuntimeError("Translated output has no extractable text.")
                            if any(ord(char) < 32 and char not in "\t\n\r" for char in text):
                                raise RuntimeError("Translated output contains invalid control characters in its text mapping.")
                            searchable = 0
                            for page in pdf:
                                for match in re.finditer(r"[^\W\d_]+ +[^\W\d_]+", page.get_text()):
                                    phrase = match.group()
                                    if any(ord(char) > 127 for char in phrase) and page.search_for(phrase):
                                        searchable += 1
                                        break
                            if not searchable:
                                raise RuntimeError("Translated output has no searchable Vietnamese phrase with a normal space.")
                            outputs[kind] = {"file": destination.name, "pages": pdf.page_count,
                                             "bytes": destination.stat().st_size, "text_characters": len(text),
                                             "searchable_vietnamese_pages": searchable}
                    write({**state, "verification": "passed", "verified_outputs": outputs})
                    return 0
                time.sleep(.5)
            manager.cancel(job["id"])
            write({"status": "failed", "error": "Live translation verification timed out."})
            return 2
        except Exception as error:
            write({"status": "failed", "error": f"{type(error).__name__}: {error}"})
            return 2
        finally:
            manager.shutdown()
