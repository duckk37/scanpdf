"""Manual network QA using the production JobManager, never a mocked translator."""
import argparse
import json
import multiprocessing
import shutil
import tempfile
import time
from pathlib import Path

from scanpdf.services.jobs import JobManager, TranslationSettings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--service", choices=["google", "bing"], default="google")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="scanpdf-live-") as temporary:
        manager = JobManager(Path(temporary) / "jobs")
        try:
            job = manager.submit_file(arguments.source, TranslationSettings(service=arguments.service,
                                       source="en" if arguments.service == "bing" else "auto"))
            last = None
            while True:
                state = manager.status(job["id"])
                marker = (state["status"], int(state["progress"]), state["stage"])
                if marker != last:
                    print(json.dumps(state, ensure_ascii=True), flush=True)
                    last = marker
                if state["status"] in {"completed", "failed", "cancelled"}:
                    break
                time.sleep(1)
            if state["status"] != "completed":
                return 1
            arguments.output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(manager.download_path(job["id"], "mono"), arguments.output)
            if "dual" in state["outputs"]:
                shutil.copyfile(manager.download_path(job["id"], "dual"), arguments.output.with_stem(arguments.output.stem + "-dual"))
            return 0
        finally:
            manager.shutdown()


if __name__ == "__main__":
    multiprocessing.freeze_support()
    raise SystemExit(main())
