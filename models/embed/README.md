# models/embed

Place the embedding model used to build and query `index/` here
(BAC-149, BAC-150). Changing this model later forces a full re-index,
so it should not be swapped lightly (BAC-154).

Default model: `bge-small-en-v1.5/` with `embed.json`, `model.onnx` and
`tokenizer.json` (fetch with `scripts/index fetch-model`). Details in
[docs/INDEX.md](../../docs/INDEX.md).
