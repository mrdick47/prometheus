# models/

Tiered llamafile / GGUF weights and the embedding model (BAC-149).
Git ignores weight files (`*.gguf`, `*.llamafile`, and similar).

| Subfolder | Role |
| --- | --- |
| `low/` | Qwen or Llama ~3B, for laptops and old PCs (CPU, about 8 GB RAM) |
| `mid/` | Qwen ~8B, for decent laptops (16 GB RAM or a modest GPU) |
| `high/` | Qwen 14B–32B, for a gaming PC like POSEIDON and its GPU |
| `embed/` | Small embedding model (nomic-embed-text, bge-small, or a better current equivalent, under ~500 MB) |

Qwen is the default primary family unless a later check (BAC-149)
picks a clearly better RAG option at the same size. Granite is the
planned citation-disciplined alternative. Exact filenames will be
recorded here when models are chosen. Until then the launcher looks
for `*.llamafile` first, then `*.gguf`.
