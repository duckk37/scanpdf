"""Local PDF operations. All page indices are zero based; outputs are atomic."""
from __future__ import annotations

import contextlib
import os
import tempfile
from pathlib import Path
from typing import Iterable

import pymupdf
from PIL import Image, ImageOps


class PDFError(ValueError):
    pass


def open_document(path: str | Path, password: str = "") -> pymupdf.Document:
    try:
        document = pymupdf.open(Path(path))
        if not document.is_pdf:
            raise PDFError("Tệp được chọn không phải PDF.")
        was_protected = bool(document.needs_pass)
        if was_protected and not document.authenticate(password):
            raise PDFError("PDF có mật khẩu. Hãy nhập mật khẩu đúng.")
        # In PyMuPDF 1.25.2 asking needs_pass again after authentication resets
        # the decryption key. Cache the original flag before authenticating.
        document._scanpdf_password_protected = was_protected
        if document.page_count == 0:
            raise PDFError("PDF không có trang.")
        return document
    except Exception as error:
        if "document" in locals():
            document.close()
        if isinstance(error, PDFError):
            raise
        raise PDFError("Không thể mở PDF. Tệp có thể đã bị hỏng.") from error


def inspect(path: str | Path, password: str = "") -> dict:
    with open_document(path, password) as document:
        return {"page_count": len(document), "encrypted": document._scanpdf_password_protected,
                "title": document.metadata.get("title", ""),
                "pages": [{"index": p.number, "width": p.rect.width,
                           "height": p.rect.height, "rotation": p.rotation} for p in document]}


def _indices(pages: Iterable[int], count: int, *, unique: bool = True) -> list[int]:
    values = list(pages)
    if not values or any(type(p) is not int or not 0 <= p < count for p in values):
        raise PDFError("Danh sách trang trống hoặc nằm ngoài PDF.")
    if unique and len(set(values)) != len(values):
        raise PDFError("Danh sách trang không được lặp lại.")
    return values


def _save(document: pymupdf.Document, output: str | Path, inputs=(), **kwargs) -> Path:
    output = Path(output).resolve()
    if any(output == Path(p).resolve() for p in inputs):
        raise PDFError("Chọn tên tệp xuất khác để giữ lại PDF gốc.")
    if not len(document):
        raise PDFError("Không thể lưu PDF không có trang.")
    output.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(suffix=".pdf", dir=output.parent)
    os.close(handle)
    try:
        document.save(temporary, garbage=4, deflate=True, **kwargs)
        with open_document(temporary, kwargs.get("user_pw", "")) as verified:
            if len(verified) != len(document):
                raise PDFError("PDF xuất chưa đầy đủ.")
        os.replace(temporary, output)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
    return output


def _keep_encryption(document: pymupdf.Document, password: str) -> dict:
    # Copying into a new PDF removes encryption; preserve the entered password.
    return ({"encryption": pymupdf.PDF_ENCRYPT_AES_256, "user_pw": password,
             "owner_pw": password} if password and getattr(document, "_scanpdf_password_protected", False) else {})


def merge(paths, output, passwords=None) -> Path:
    paths = list(paths)
    if not paths:
        raise PDFError("Chọn ít nhất một PDF để ghép.")
    passwords = list(passwords or [""] * len(paths))
    if len(passwords) != len(paths):
        raise PDFError("Số mật khẩu không khớp số PDF.")
    with pymupdf.open() as result:
        encryption = {}
        for path, password in zip(paths, passwords):
            with open_document(path, password) as source:
                if not len(result):
                    encryption = _keep_encryption(source, password)
                result.insert_pdf(source)
        return _save(result, output, paths, **encryption)


def extract(path, output, pages, password="") -> Path:
    with open_document(path, password) as source, pymupdf.open() as result:
        for index in _indices(pages, len(source)):
            result.insert_pdf(source, from_page=index, to_page=index)
        return _save(result, output, [path], **_keep_encryption(source, password))


def rotate(path, output, pages, degrees=90, password="") -> Path:
    if type(degrees) is not int or degrees % 90:
        raise PDFError("Góc xoay phải là bội số của 90 độ.")
    with open_document(path, password) as source:
        for index in _indices(pages, len(source)):
            page = source[index]
            page.set_rotation((page.rotation + degrees) % 360)
        return _save(source, output, [path], **_keep_encryption(source, password))


def delete_pages(path, output, pages, password="") -> Path:
    with open_document(path, password) as source:
        values = _indices(pages, len(source))
        if len(values) == len(source):
            raise PDFError("Cần giữ lại ít nhất một trang.")
        source.delete_pages(sorted(values))
        return _save(source, output, [path], **_keep_encryption(source, password))


def reorder(path, output, order, password="") -> Path:
    with open_document(path, password) as source:
        values = _indices(order, len(source))
        if len(values) != len(source):
            raise PDFError("Thứ tự mới phải chứa đủ các trang, mỗi trang một lần.")
        source.select(values)
        return _save(source, output, [path], **_keep_encryption(source, password))


def duplicate(path, output, pages, password="") -> Path:
    with open_document(path, password) as source, pymupdf.open() as result:
        selected = set(_indices(pages, len(source)))
        for index in range(len(source)):
            result.insert_pdf(source, from_page=index, to_page=index)
            if index in selected:
                result.insert_pdf(source, from_page=index, to_page=index)
        return _save(result, output, [path], **_keep_encryption(source, password))


def insert(path, other, output, at, password="", other_password="") -> Path:
    with open_document(path, password) as source, open_document(other, other_password) as extra:
        if type(at) is not int or not 0 <= at <= len(source):
            raise PDFError("Vị trí chèn không hợp lệ.")
        source.insert_pdf(extra, start_at=at)
        return _save(source, output, [path, other], **_keep_encryption(source, password))


def _render(page: pymupdf.Page, dimension: int) -> pymupdf.Pixmap:
    scale = dimension / max(page.rect.width, page.rect.height)
    return page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), colorspace=pymupdf.csRGB, alpha=False)


def compress(path, output, quality=75, max_dimension=1600, password="") -> Path:
    if not 20 <= quality <= 95 or not 300 <= max_dimension <= 6000:
        raise PDFError("Chất lượng nén hoặc kích thước ảnh không hợp lệ.")
    with open_document(path, password) as source, pymupdf.open() as result:
        for page in source:
            image = _render(page, max_dimension)
            target = result.new_page(width=page.rect.width, height=page.rect.height)
            target.insert_image(target.rect, stream=image.tobytes("jpeg", jpg_quality=quality))
        return _save(result, output, [path], **_keep_encryption(source, password))


def watermark(path, output, text, password="") -> Path:
    if not text.strip() or len(text) > 300:
        raise PDFError("Nhập nội dung dấu mờ từ 1 đến 300 ký tự.")
    with open_document(path, password) as source:
        for page in source:
            # Built-in CJK font fallback is inadequate for Vietnamese; insert_htmlbox
            # uses MuPDF's bundled universal fallback fonts and keeps native content.
            import html
            width, height = page.rect.width, page.rect.height
            rect = pymupdf.Rect(width * .05, height * .43, width * .95, height * .57)
            page.insert_htmlbox(rect, f"<div>{html.escape(text)}</div>",
                                css="div{text-align:center;font-size:24pt;color:#888;}",
                                opacity=.25, scale_low=0)
        return _save(source, output, [path], **_keep_encryption(source, password))


def protect(path, output, new_password, password="") -> Path:
    if not new_password or len(new_password.encode("utf-8")) > 127:
        raise PDFError("Mật khẩu phải có từ 1 đến 127 byte UTF-8.")
    with open_document(path, password) as source:
        return _save(source, output, [path], encryption=pymupdf.PDF_ENCRYPT_AES_256,
                     user_pw=new_password, owner_pw=new_password)


def unlock(path, output, password) -> Path:
    with open_document(path, password) as source:
        return _save(source, output, [path], encryption=pymupdf.PDF_ENCRYPT_NONE)


def number_pages(path, output, start=1, position="bottom-center", password="") -> Path:
    positions = {f"{vertical}-{horizontal}" for vertical in ("top", "bottom")
                 for horizontal in ("left", "center", "right")}
    if type(start) is not int or not 1 <= start <= 1_000_000 or position not in positions:
        raise PDFError("Số bắt đầu hoặc vị trí đánh số không hợp lệ.")
    with open_document(path, password) as source:
        for index, page in enumerate(source):
            width, height = page.rect.width, page.rect.height
            margin = min(24, min(width, height) * .08)
            font_size = min(11, min(width, height) * .12)
            text = str(start + index)
            text_width = pymupdf.get_text_length(text, fontsize=font_size)
            horizontal = position.split("-")[1]
            x = {"left": margin, "center": (width - text_width) / 2,
                 "right": width - margin - text_width}[horizontal]
            y = margin + font_size if position.startswith("top") else height - margin
            page.insert_text(pymupdf.Point(max(0, x), y), text, fontsize=font_size)
        return _save(source, output, [path], **_keep_encryption(source, password))


def export_images(path, output_dir, format="png", max_dimension=2000, pages=None, password="") -> list[Path]:
    if format not in ("png", "jpeg") or type(max_dimension) is not int or not 300 <= max_dimension <= 6000:
        raise PDFError("Định dạng hoặc kích thước ảnh không hợp lệ.")
    directory = Path(output_dir).resolve()
    with open_document(path, password) as source:
        values = _indices(range(len(source)) if pages is None else pages, len(source))
        pixel_count = sum(max_dimension ** 2 * min(source[p].rect.width, source[p].rect.height)
                          / max(source[p].rect.width, source[p].rect.height) for p in values)
        if len(values) > 100 or pixel_count > 100_000_000:
            raise PDFError("Xuất tối đa 100 trang và 100 triệu pixel mỗi lần. Hãy chọn ít trang hơn.")
        directory.mkdir(parents=True, exist_ok=True)
        paths = [directory / f"page-{p + 1:04d}.{('jpg' if format == 'jpeg' else 'png')}" for p in values]
        if any(p.exists() for p in paths):
            raise PDFError("Thư mục đã có ảnh trùng tên. Hãy chọn thư mục mới.")
        written = []
        try:
            for index, output in zip(values, paths):
                _render(source[index], max_dimension).save(output)
                written.append(output)
        except Exception:
            for output in written:
                with contextlib.suppress(OSError):
                    output.unlink()
            raise
        return paths


def images_to_pdf(paths, output, paper="original", filter="original") -> Path:
    paths = list(paths)
    if not paths or paper not in ("original", "a4", "letter") or filter not in ("original", "grayscale", "blackAndWhite"):
        raise PDFError("Ảnh, khổ giấy hoặc bộ lọc không hợp lệ.")
    with pymupdf.open() as result:
        for path in paths:
            with Image.open(path) as raw:
                image = ImageOps.exif_transpose(raw).convert("RGB")
                image.thumbnail((6000, 6000))
                if filter != "original":
                    image = ImageOps.grayscale(image)
                    if filter == "blackAndWhite":
                        image = ImageOps.autocontrast(image).point(lambda value: 255 if value >= 160 else 0)
                size = {"a4": (595.28, 841.89), "letter": (612, 792)}.get(paper, image.size)
                page = result.new_page(width=size[0], height=size[1])
                rect = page.rect if paper == "original" else pymupdf.Rect(24, 24, size[0] - 24, size[1] - 24)
                import io
                stream = io.BytesIO()
                image.save(stream, format="PNG")
                page.insert_image(rect, stream=stream.getvalue(), keep_proportion=True)
        return _save(result, output, paths)
