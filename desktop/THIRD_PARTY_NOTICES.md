# ScanPDF Desktop · Third-party notices

ScanPDF Desktop is distributed under the GNU Affero General Public License, version 3 or later. The full text is in `LICENSE`. Corresponding application/build sources are provided in `ScanPDF-Desktop-Source.zip` alongside the Windows download and at [duckk37/scanpdf](https://github.com/duckk37/scanpdf). This notice applies to the Windows desktop component.

The translation and PDF libraries are unmodified upstream releases. Their exact source archives, download URLs and SHA-256 hashes are included in the source ZIP. Installed distribution license/copyright files and versions are retained under `_internal/licenses/DEPENDENCIES.json` and adjacent folders. Those libraries remain subject to their own licenses; the application's license does not replace them.

| Component | Version | License / source |
| --- | --- | --- |
| PDFMathTranslate Next | 2.8.2 | AGPL-3.0, [upstream](https://github.com/PDFMathTranslate/PDFMathTranslate-next), [PyPI source](https://pypi.org/project/pdf2zh-next/2.8.2/#files) |
| BabelDOC | 0.5.20 | AGPL-3.0, [upstream](https://github.com/funstory-ai/BabelDOC), [PyPI source](https://pypi.org/project/babeldoc/0.5.20/#files) |
| PyMuPDF / MuPDF | 1.25.2 | AGPL-3.0, [PyMuPDF source](https://pypi.org/project/PyMuPDF/1.25.2/#files), [MuPDF source](https://github.com/ArtifexSoftware/mupdf-downloads/releases/tag/1.25.2) |
| PySide6 / Shiboken6 / Qt | 6.8.3 | LGPL-3.0 / GPL alternatives, [Qt for Python source](https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-6.8.3-src/), [Qt 6.8.3 source](https://download.qt.io/archive/qt/6.8/6.8.3/single/) |
| ONNX / ONNX Runtime | Pinned in requirements.txt | Apache-2.0 / MIT, [ONNX](https://github.com/onnx/onnx), [ONNX Runtime](https://github.com/microsoft/onnxruntime) |
| OpenCV | 4.11.0.86 | Apache-2.0 and bundled third-party notices, [source](https://github.com/opencv/opencv/tree/4.11.0) |
| Levenshtein / python-Levenshtein | Pinned in requirements.txt | GPL-2.0-or-later, [source](https://github.com/rapidfuzz/Levenshtein) |
| PyInstaller bootloader | 6.22.3 | GPL-2.0-or-later with the bootloader exception, [license](https://pyinstaller.org/en/stable/license.html) |

Qt is dynamically linked in the folder distribution. Its LGPL-3.0 and GPL-3.0 license texts are supplied under `_internal/licenses/Qt/`. Users may replace the Qt/PySide libraries with compatible modified builds and debug those modifications. No restriction against reverse engineering those library modifications is imposed by ScanPDF. Keep the complete EXE folder; do not move only the executable. Exact upstream source versions and build instructions are available through the Qt links above.

BabelDOC's layout model and font cache are downloaded at runtime. The RapidOCR wheel also contains its default OCR models; those are retained in the folder distribution. Their original notices remain applicable:

- [DocLayout ONNX model card](https://huggingface.co/wybxc/DocLayout-YOLO-DocStructBench-onnx) declares Apache-2.0 and identifies its base model. The [DocLayout-YOLO code](https://github.com/opendatalab/DocLayout-YOLO) has its own AGPL-3.0 license.
- [RapidOCR](https://github.com/RapidAI/RapidOCR) and its Paddle OCR model notices are Apache-2.0.
- BabelDOC's [font sources and license links](https://github.com/funstory-ai/BabelDOC-Assets/blob/main/README.md) include SIL Open Font License 1.1, Go Noto Universal's Unlicense and MaruBuri's font license. Fonts are not relicensed by ScanPDF.

Python and all other bundled dependencies have their own copyright/license notices in the generated license inventory. Dependency sources can be retrieved at the exact version through the inventory's PyPI metadata links. Build-time dependencies that are included in that inventory are identified by `requirements-build.txt`.
