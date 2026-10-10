from pathlib import Path

import pymupdf
import pytest
from PIL import Image

from scanpdf.services import pdf_ops as pdf


@pytest.fixture
def source(tmp_path):
    path = tmp_path / "source.pdf"
    with pymupdf.open() as document:
        for label in ("First page", "Second page", "Third page"):
            page = document.new_page(width=400, height=600)
            page.insert_text((30, 60), label, fontsize=18)
            page.draw_rect(pymupdf.Rect(50, 100, 150, 200), fill=(1, 0, 0), color=(1, 0, 0))
            page.add_text_annot((200, 200), "Keep annotation")
        document.save(path)
    return path


def texts(path, password=""):
    with pdf.open_document(path, password) as document:
        return [page.get_text().strip() for page in document]


def test_reorder_extract_insert_duplicate_keep_content_and_order(source, tmp_path):
    reordered = pdf.reorder(source, tmp_path / "reorder.pdf", [2, 0, 1])
    assert texts(reordered) == ["Third page", "First page", "Second page"]
    extracted = pdf.extract(source, tmp_path / "extract.pdf", [1, 0])
    assert texts(extracted) == ["Second page", "First page"]
    duplicated = pdf.duplicate(source, tmp_path / "duplicate.pdf", [0, 2])
    assert texts(duplicated) == ["First page", "First page", "Second page", "Third page", "Third page"]
    inserted = pdf.insert(source, extracted, tmp_path / "insert.pdf", 1)
    assert texts(inserted) == ["First page", "Second page", "First page", "Second page", "Third page"]
    with pdf.open_document(inserted) as result:
        assert len(list(result[1].annots())) == 1
        pix = result[1].get_pixmap()
        assert pix.pixel(80, 150)[:3] == (255, 0, 0)


def test_encryption_survives_authenticated_operations_and_unlock(source, tmp_path):
    encrypted = pdf.protect(source, tmp_path / "protected.pdf", "mật-khẩu")
    assert texts(encrypted, "mật-khẩu") == texts(source)
    assert pdf.inspect(encrypted, "mật-khẩu")["encrypted"]
    with pytest.raises(pdf.PDFError):
        pdf.open_document(encrypted, "wrong")
    operations = [lambda out: pdf.rotate(encrypted, out, [0], password="mật-khẩu"),
                  lambda out: pdf.extract(encrypted, out, [1], password="mật-khẩu"),
                  lambda out: pdf.duplicate(encrypted, out, [0], password="mật-khẩu"),
                  lambda out: pdf.merge([encrypted, source], out, ["mật-khẩu", ""])]
    for index, operation in enumerate(operations):
        output = operation(tmp_path / f"encrypted-{index}.pdf")
        with pymupdf.open(output) as result:
            assert result.needs_pass
            assert result.authenticate("mật-khẩu")
            assert "page" in result[0].get_text()
            assert len(list(result[0].annots())) == 1
            assert result[0].get_images() == []  # Original red drawing stays vector.
    unlocked = pdf.unlock(encrypted, tmp_path / "unlocked.pdf", "mật-khẩu")
    assert not pdf.inspect(unlocked)["encrypted"]
    assert texts(unlocked) == texts(source)


def test_number_watermark_preserve_text_images_annotations(source, tmp_path):
    numbered = pdf.number_pages(source, tmp_path / "numbers.pdf", start=8, position="top-right")
    marked = pdf.watermark(numbered, tmp_path / "watermark.pdf", "Bản tham khảo")
    with pdf.open_document(marked) as result:
        for index, page in enumerate(result):
            assert str(index + 8) in page.get_text()
            assert "page" in page.get_text()
            assert "Bản tham khảo" in page.get_text()
            assert len(list(page.annots())) == 1
            assert page.get_pixmap().pixel(80, 150)[:3] == (255, 0, 0)


def test_images_paper_aspect_export_pixels_and_raster_compression(source, tmp_path):
    image_path = tmp_path / "image.png"
    Image.new("RGB", (200, 100), (0, 40, 200)).save(image_path)
    scanned = pdf.images_to_pdf([image_path], tmp_path / "scan.pdf", paper="a4")
    with pdf.open_document(scanned) as document:
        page = document[0]
        assert page.rect.width == pytest.approx(595.28, abs=.01)
        assert page.rect.height == pytest.approx(841.89, abs=.01)
        image_rect = pymupdf.Rect(page.get_image_info()[0]["bbox"])
        assert image_rect.width / image_rect.height == pytest.approx(2)
        assert image_rect.x0 >= 23.9 and image_rect.x1 <= page.rect.width - 23.9
    paths = pdf.export_images(source, tmp_path / "images", format="jpeg", max_dimension=1200, pages=[1])
    assert len(paths) == 1
    with Image.open(paths[0]) as image:
        assert image.size == (800, 1200)
        red = image.getpixel((160, 300))
        assert red[0] > 240 and red[1] < 15 and red[2] < 15
    compressed = pdf.compress(source, tmp_path / "compressed.pdf", quality=80)
    with pdf.open_document(compressed) as document:
        assert len(document) == 3
        assert document[0].get_pixmap().pixel(80, 150)[0] > 240
        assert document[0].get_images()


def test_invalid_operations_preserve_source_and_destination(source, tmp_path):
    original = source.read_bytes()
    destination = tmp_path / "existing.pdf"
    destination.write_bytes(b"keep destination")
    with pytest.raises(pdf.PDFError):
        pdf.delete_pages(source, destination, [0, 1, 2])
    assert destination.read_bytes() == b"keep destination"
    with pytest.raises(pdf.PDFError):
        pdf.reorder(source, destination, [0, 0, 1])
    with pytest.raises(pdf.PDFError):
        pdf.rotate(source, source, [0])
    large = tmp_path / "large.pdf"
    with pdf.open_document(source) as document:
        document.new_page(width=400, height=600)
        document.new_page(width=400, height=600)
        document.save(large)
    with pytest.raises(pdf.PDFError):
        pdf.export_images(large, tmp_path / "huge", max_dimension=6000)
    assert source.read_bytes() == original
