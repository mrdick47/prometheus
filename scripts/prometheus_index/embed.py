"""Embedding backends. The real one is an ONNX model run fully offline.

Model directory (``<drive>/models/embed/<name>/``):
    embed.json       name, dim, max_len, pooling, query_prefix, doc_prefix
    model.onnx       the model (fp32 so CPU and GPU give the same vectors)
    tokenizer.json   HF fast tokenizer

Device: ``auto`` picks CUDA when onnxruntime exposes it, otherwise CPU.
A ``type: "hash"`` embed.json gives a deterministic dependency-free embedder
used by the unit tests.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

import numpy as np

QUANT = "int8"


def quantize_int8(v: np.ndarray) -> np.ndarray:
    """L2-normalised float rows -> int8 with a fixed scale of 127."""
    return np.clip(np.rint(v * 127.0), -127, 127).astype(np.int8)


def _l2(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v, axis=1, keepdims=True)
    n[n == 0] = 1.0
    return (v / n).astype(np.float32)


class Embedder:
    name: str
    dim: int
    fingerprint: str
    device: str = "cpu"
    query_prefix: str = ""
    doc_prefix: str = ""

    def embed(self, texts: list[str], is_query: bool = False) -> np.ndarray:  # float32 normalised
        raise NotImplementedError


class HashEmbedder(Embedder):
    """Bag-of-words feature hashing. Similar texts get similar vectors."""

    def __init__(self, cfg: dict):
        self.name = cfg.get("name", "hash-test")
        self.dim = int(cfg.get("dim", 64))
        self.fingerprint = f"hash:{self.dim}"
        self.device = "cpu"

    def embed(self, texts, is_query=False):
        out = np.zeros((len(texts), self.dim), dtype=np.float32)
        for i, t in enumerate(texts):
            for w in re.findall(r"\w+", t.lower()):
                h = int.from_bytes(hashlib.blake2b(w.encode(), digest_size=8).digest(), "little")
                out[i, h % self.dim] += 1.0 if (h >> 63) & 1 else -1.0
        return _l2(out)


class OnnxEmbedder(Embedder):
    def __init__(self, model_dir: Path, cfg: dict, device: str = "auto", threads: int = 0):
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self.name = cfg["name"]
        self.dim = int(cfg["dim"])
        self.pooling = cfg.get("pooling", "cls")
        self.max_len = int(cfg.get("max_len", 256))
        self.query_prefix = cfg.get("query_prefix", "")
        self.doc_prefix = cfg.get("doc_prefix", "")
        onnx_path = model_dir / cfg.get("onnx", "model.onnx")
        self.fingerprint = f"onnx:{self.name}:{onnx_path.stat().st_size}"
        self.tok = Tokenizer.from_file(str(model_dir / cfg.get("tokenizer", "tokenizer.json")))
        self.tok.enable_truncation(max_length=self.max_len)
        self.tok.enable_padding(pad_id=cfg.get("pad_id", 0), pad_token=cfg.get("pad_token", "[PAD]"))
        if hasattr(ort, "preload_dlls") and device != "cpu":
            try:
                ort.preload_dlls()  # lets pip-installed CUDA/cuDNN wheels be found
            except Exception:
                pass
        avail = ort.get_available_providers()
        want_cuda = device in ("auto", "cuda") and "CUDAExecutionProvider" in avail
        if device == "cuda" and not want_cuda:
            raise RuntimeError("device=cuda requested but CUDAExecutionProvider is unavailable")
        so = ort.SessionOptions()
        so.log_severity_level = 3
        if threads:
            so.intra_op_num_threads = threads
        providers = (["CUDAExecutionProvider"] if want_cuda else []) + ["CPUExecutionProvider"]
        self.sess = ort.InferenceSession(str(onnx_path), so, providers=providers)
        self.device = "cuda" if self.sess.get_providers()[0] == "CUDAExecutionProvider" else "cpu"
        self.input_names = {i.name for i in self.sess.get_inputs()}

    def embed(self, texts, is_query=False):
        pre = self.query_prefix if is_query else self.doc_prefix
        enc = self.tok.encode_batch([pre + t for t in texts])
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in self.input_names:
            feed["token_type_ids"] = np.zeros_like(ids)
        hidden = self.sess.run(None, feed)[0]
        if self.pooling == "mean":
            m = mask[..., None].astype(np.float32)
            vec = (hidden * m).sum(1) / np.maximum(m.sum(1), 1.0)
        else:
            vec = hidden[:, 0, :]
        return _l2(vec.astype(np.float32))


def find_model_dir(drives: list[Path], name: str | None = None) -> Path | None:
    """Look in <drive>/models/embed/ on every connected drive (first match wins)."""
    for d in drives:
        base = d / "models" / "embed"
        if not base.is_dir():
            continue
        cands = [base / name] if name else sorted(p for p in base.iterdir() if p.is_dir())
        for c in cands:
            if (c / "embed.json").is_file():
                return c
    return None


def load_embedder(drives: list[Path], name: str | None = None, device: str = "auto",
                  threads: int = 0) -> Embedder:
    mdir = find_model_dir(drives, name)
    if mdir is None:
        raise FileNotFoundError(
            "no embedding model found under models/embed/<name>/embed.json on any "
            "connected drive (run: index fetch-model)")
    cfg = json.loads((mdir / "embed.json").read_text(encoding="utf-8"))
    if cfg.get("type") == "hash":
        return HashEmbedder(cfg)
    return OnnxEmbedder(mdir, cfg, device=device, threads=threads)
