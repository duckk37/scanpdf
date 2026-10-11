"""Exercise BabelDOC's real CMap outline filter with a deterministic local font."""
import io

import pymupdf
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from PIL import Image

from scanpdf.services.jobs import _install_pdf_space_mapping_fix


def font_bytes():
    # SPACE is deliberately CID 4, disproving any hardcoded CID3 workaround.
    characters = sorted(set("Năng lượng có thể thực hiện công"))
    order = [".notdef", "dummy1", "dummy2", "dummy3", "space"]
    order += [f"uni{ord(char):04X}" for char in characters if char != " "]
    mapping = {ord(char): "space" if char == " " else f"uni{ord(char):04X}" for char in characters}
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
    builder.setupCharacterMap(mapping)
    builder.setupNameTable({"familyName": "ScanPDF Spacing Regression", "styleName": "Regular",
                           "uniqueFontIdentifier": "ScanPDFSpacingRegression-Regular",
                           "fullName": "ScanPDF Spacing Regression Regular",
                           "psName": "ScanPDFSpacingRegression-Regular"})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    builder.setupMaxp()
    stream = io.BytesIO()
    builder.save(stream)
    return stream.getvalue()


def pdf_fixture():
    document = pymupdf.open()
    page = document.new_page(width=400, height=500)
    font_xref = page.insert_font(fontname="Generated.ttf", fontbuffer=font_bytes())
    page.insert_text((30, 70), "Năng lượng có thể thực hiện công", fontname="Generated.ttf", fontsize=13)
    page.insert_text((40, 140), "E = m c", fontname="tiit", fontsize=18)
    page.insert_text((106, 130), "2", fontname="tiit", fontsize=11)
    image = io.BytesIO()
    Image.new("RGB", (20, 30), (230, 30, 10)).save(image, format="PNG")
    page.insert_image(pymupdf.Rect(40, 200, 140, 350), stream=image.getvalue())
    return document, font_xref


def test_real_babeldoc_filter_loses_non3_space_and_wrapper_restores_search_without_visual_changes(monkeypatch):
    from babeldoc.format.pdf.document_il.backend import pdf_creater
    original = getattr(pdf_creater.reproduce_one_font, "_scanpdf_original", pdf_creater.reproduce_one_font)
    monkeypatch.setattr(pdf_creater, "reproduce_one_font", original)
    with_doc, font_xref = pdf_fixture()
    try:
        cmap_xref = int(with_doc.xref_get_key(font_xref, "ToUnicode")[1].split()[0])
        assert pdf_creater.parse_tounicode_cmap(with_doc.xref_stream(cmap_xref))[4] == 32
        original(with_doc, font_xref)
        with pymupdf.open(stream=with_doc.tobytes(), filetype="pdf") as broken:
            assert not broken[0].search_for("Năng lượng")
            assert chr(4) in broken[0].get_text()
    finally:
        with_doc.close()

    fixed, font_xref = pdf_fixture()
    try:
        before_pixels = fixed[0].get_pixmap().samples
        before_contents = [fixed.xref_stream(xref) for xref in fixed[0].get_contents()]
        before_formula = fixed[0].search_for("E = m c")
        before_image = fixed[0].get_image_info(hashes=True)
        _install_pdf_space_mapping_fix()
        wrapper = pdf_creater.reproduce_one_font
        _install_pdf_space_mapping_fix()
        assert pdf_creater.reproduce_one_font is wrapper  # No stacked wrappers.
        wrapper(fixed, font_xref)
        assert [fixed.xref_stream(xref) for xref in fixed[0].get_contents()] == before_contents
        with pymupdf.open(stream=fixed.tobytes(), filetype="pdf") as persisted:
            assert persisted[0].search_for("Năng lượng")
            assert "Năng lượng có thể thực hiện công" in persisted[0].get_text()
            assert chr(4) not in persisted[0].get_text()
            assert persisted[0].get_pixmap().samples == before_pixels
            assert persisted[0].search_for("E = m c") == before_formula
            assert persisted[0].get_image_info(hashes=True)[0]["digest"] == before_image[0]["digest"]
            assert persisted[0].get_image_info()[0]["bbox"] == before_image[0]["bbox"]
    finally:
        fixed.close()


def test_wrapper_leaves_existing_nonspace_mappings_and_unrelated_fonts_unchanged(monkeypatch):
    from babeldoc.format.pdf.document_il.backend import pdf_creater
    original = getattr(pdf_creater.reproduce_one_font, "_scanpdf_original", pdf_creater.reproduce_one_font)
    monkeypatch.setattr(pdf_creater, "reproduce_one_font", original)
    document, font_xref = pdf_fixture()
    try:
        cmap_xref = int(document.xref_get_key(font_xref, "ToUnicode")[1].split()[0])
        before = pdf_creater.parse_tounicode_cmap(document.xref_stream(cmap_xref))
        _install_pdf_space_mapping_fix()
        pdf_creater.reproduce_one_font(document, font_xref)
        after = pdf_creater.parse_tounicode_cmap(document.xref_stream(cmap_xref))
        assert all(after[cid] == code for cid, code in before.items())
        italic_xref = next(font[0] for font in document[0].get_fonts() if font[3] == "Times-Italic")
        italic_before = document.xref_object(italic_xref)
        pdf_creater.reproduce_one_font(document, italic_xref)
        assert document.xref_object(italic_xref) == italic_before
    finally:
        document.close()
