import json
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
pytest.importorskip("libzim")
pytest.importorskip("numpy")

from libzim.writer import Creator, Hint, Item, StringProvider  # noqa: E402

from prometheus_index.config import Source, DEFAULTS  # noqa: E402
from prometheus_index.embed import HashEmbedder  # noqa: E402


class _Page(Item):
    def __init__(self, path, title, html):
        super().__init__()
        self._p, self._t, self._h = path, title, html

    def get_path(self): return self._p
    def get_title(self): return self._t
    def get_mimetype(self): return "text/html"
    def get_contentprovider(self): return StringProvider(self._h)
    def get_hints(self): return {Hint.FRONT_ARTICLE: True}


class _Bin(Item):
    def __init__(self, path):
        super().__init__()
        self._p = path
    def get_path(self): return self._p
    def get_title(self): return ""
    def get_mimetype(self): return "image/png"
    def get_contentprovider(self): return StringProvider("\x89PNG-not-really")
    def get_hints(self): return {Hint.FRONT_ARTICLE: False}


def page_html(topic: str, n: int = 6) -> str:
    paras = "".join(
        f"<p>{topic} paragraph {i}: " + (f"{topic} " * 40) + f"fact number {i} about {topic}.</p>"
        for i in range(n))
    return f"<html><head><title>{topic}</title><script>var x=1;</script></head><body><h1>{topic}</h1>{paras}</body></html>"


def make_zim(path: Path, pages: dict[str, str]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    with Creator(str(path)).config_indexing(False, "en") as c:
        c.set_mainpath(next(iter(pages)))
        for p, html in pages.items():
            c.add_item(_Page(p, p, html))
        c.add_item(_Bin("img.png"))
    return path


class Env:
    """A throwaway drive with library/ and run/verified/."""

    def __init__(self, root: Path):
        self.root = root
        (root / "library").mkdir(parents=True)
        (root / "run" / "verified").mkdir(parents=True)
        self.emb = HashEmbedder({"dim": 32})
        self.settings = dict(DEFAULTS, checkpoint_chunks="6", embed_batch="8")

    def zim(self, name="demo_en_2026-01.zim", pages=None) -> Source:
        z = make_zim(self.root / "library" / name,
                     pages or {f"A/{t}": page_html(t) for t in ["alpha", "beta", "gamma", "delta", "epsilon"]})
        (self.root / "run" / "verified" / (name + ".verified.json")).write_text(
            json.dumps({"filename": name, "size": z.stat().st_size}))
        from prometheus_index.config import is_verified, source_id
        s = Source(id=source_id(name), drive=self.root, zim=z)
        s.verified = is_verified(self.root, z)
        return s


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path / "drive")
