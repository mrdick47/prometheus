"""Deterministic text extraction and chunking.

The index stores (article path, start, end) byte offsets into the text this
module produces, so extraction must be reproducible: the extractor version is
recorded in each index and a mismatch forces a rebuild.
"""
from __future__ import annotations

import io
import re
from html.parser import HTMLParser

import importlib.util
import logging

# pypdf decodes some fonts differently when fontTools is installed, which moves
# offsets, so its presence is part of the extractor identity (a change flags the
# index as model-mismatch and asks for a rebuild instead of returning wrong text).
EXTRACTOR_VERSION = "html-v1+pdf-pypdf-v1" + (
    "+ft" if importlib.util.find_spec("fontTools") else "")
logging.getLogger("pypdf").setLevel(logging.ERROR)
CHUNK_MAX_BYTES = 1200
CHUNK_MIN_BYTES = 24
MAX_CHUNKS_PER_ARTICLE = 256

_SKIP = {"script", "style", "noscript", "svg", "head", "template", "nav", "footer"}
_BLOCK = {
    "p", "div", "br", "li", "ul", "ol", "tr", "table", "section", "article", "h1", "h2",
    "h3", "h4", "h5", "h6", "pre", "blockquote", "dd", "dt", "dl", "hr", "figure",
    "figcaption", "caption", "main", "aside", "header", "form", "body", "html",
}
_WS = re.compile(r"[ \t\r\f\v\u00a0]+")


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in _SKIP:
            self.skip += 1
        elif tag in _BLOCK:
            self.parts.append("\n")

    def handle_startendtag(self, tag, attrs):
        if tag in _BLOCK and tag not in _SKIP:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in _SKIP:
            self.skip = max(0, self.skip - 1)
        elif tag in _BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def _normalize(raw: str) -> str:
    lines = [_WS.sub(" ", ln).strip() for ln in raw.replace("\r", "\n").split("\n")]
    out: list[str] = []
    blank = 0
    for ln in lines:
        if ln:
            out.append(ln)
            blank = 0
        else:
            blank += 1
            if blank == 1 and out:
                out.append("")
    return "\n".join(out).strip()


def decode_bytes(b: bytes) -> str:
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        return b.decode("utf-8", errors="replace")


def html_to_text(raw: bytes) -> str:
    p = _Text()
    try:
        p.feed(decode_bytes(raw))
        p.close()
    except Exception:
        pass
    # Single newlines from block tags become paragraph breaks via double newline.
    return _normalize("".join(p.parts).replace("\n", "\n\n"))


def pdf_to_text(raw: bytes) -> str:
    try:
        import pypdf  # optional dependency
    except ImportError:
        raise RuntimeError("pypdf is required to index PDF entries (pip install pypdf)")
    reader = pypdf.PdfReader(io.BytesIO(raw))
    pages = []
    for page in reader.pages:
        try:
            pages.append(page.extract_text() or "")
        except Exception:
            pages.append("")
    return _normalize("\n\n".join(pages))


INDEXABLE = ("text/html", "application/xhtml+xml", "text/plain", "application/pdf")


def is_indexable(mimetype: str) -> bool:
    m = mimetype.split(";")[0].strip().lower()
    return m in INDEXABLE


def entry_to_text(mimetype: str, content: bytes) -> str:
    m = mimetype.split(";")[0].strip().lower()
    if m in ("text/html", "application/xhtml+xml"):
        return html_to_text(content)
    if m == "text/plain":
        return _normalize(decode_bytes(content))
    if m == "application/pdf":
        return pdf_to_text(content)
    return ""


def chunk_offsets(text_bytes: bytes, max_bytes: int = CHUNK_MAX_BYTES,
                  min_bytes: int = CHUNK_MIN_BYTES,
                  max_chunks: int = MAX_CHUNKS_PER_ARTICLE) -> list[tuple[int, int]]:
    """Return [(start, end)] byte offsets into text_bytes. Cuts at ASCII boundaries."""
    n = len(text_bytes)
    out: list[tuple[int, int]] = []
    pos = 0
    ws = b" \n\t"
    while pos < n and len(out) < max_chunks:
        while pos < n and text_bytes[pos] in ws:
            pos += 1
        if pos >= n:
            break
        end = min(pos + max_bytes, n)
        if end < n:
            floor = pos + max_bytes // 3
            cut = text_bytes.rfind(b"\n\n", floor, end)
            if cut < 0:
                cut = text_bytes.rfind(b"\n", floor, end)
            if cut < 0:
                cut = text_bytes.rfind(b". ", floor, end)
                if cut >= 0:
                    cut += 1
            if cut < 0:
                cut = text_bytes.rfind(b" ", floor, end)
            if cut > pos:
                end = cut
            else:
                while end > pos and (text_bytes[end] & 0xC0) == 0x80:
                    end -= 1
        e = end
        while e > pos and text_bytes[e - 1] in ws:
            e -= 1
        if e - pos >= min_bytes or (not out and e > pos):
            out.append((pos, e))
        pos = max(end, pos + 1)
    return out
