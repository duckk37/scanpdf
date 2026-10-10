"""Network-free checks of the frozen executable's spawned engine worker."""
from __future__ import annotations

import multiprocessing
import json
import shutil
import tempfile
import time
from pathlib import Path


def _check_child(connection) -> None:
    try:
        import onnxruntime
        import pdf2zh_next.high_level
        from .services.jobs import TranslationSettings, _upstream_settings
        with tempfile.TemporaryDirectory(prefix="scanpdf-worker-check-") as directory:
            configuration = _upstream_settings(TranslationSettings(source="en"), Path(directory))
            connection.send({"ok": True, "provider": configuration.translate_engine_settings.translate_engine_type,
                             "language": configuration.translation.lang_out,
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
                            outputs[kind] = {"file": destination.name, "pages": pdf.page_count,
                                             "bytes": destination.stat().st_size, "text_characters": len(text)}
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
