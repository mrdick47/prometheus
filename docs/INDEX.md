# Prometheus indexer (BAC-150, BAC-188, BAC-189)

One checkpointed vector index per source, built on any host, resumable after
a crash, a power cut, an unplugged drive or Ctrl-C. Phase 4 runs the first full
build on POSEIDON's GPU; later updates re-embed only what changed.

```
scripts/index build|update|rebuild|verify|status <source|all>      (Linux/macOS)
scripts\index.ps1 build|update|rebuild|verify|status <source|all>  (Windows)
```

| Command | What it does |
| --- | --- |
| `index build <source\|all>` | Build from scratch. `all` means every eligible source with no finished index. Resumes a partial build. |
| `index update <source\|all>` | Incremental. Unchanged ZIM = instant no-op. Changed ZIM = only new/changed articles are embedded, deleted ones are dropped. |
| `index rebuild <source\|all>` | Rebuild into `index/.<source>.rebuild/` and swap it in only when finished. A failed or interrupted rebuild leaves the old index working and resumes next run. |
| `index verify <source\|all> [--deep] [--samples N]` | Per index: sqlite check, segment sizes (and `--deep` SHA-256), orphan/missing files, ZIM still matches (sampled article hashes), self-retrieval through the offsets. Reports `corrupt`, `stale`, `model-mismatch`, `building`, `missing`, `orphaned`. Exit 1 only for corrupt/failed indexes. |
| `index status` | Table: source, drive, state (`none`, `up to date`, `stale`, `building`, `failed`, `model-mismatch`, `orphaned`), size, model, quantization, build date, articles, chunks. |
| `index query "text" [-k 5]` | Search all indexes on connected drives; prints source, title, article path and byte offsets, and the text read back from the ZIM. |
| `index remove <source> [--yes]` | Delete one source's index (asks first). |
| `index pause\|resume\|cancel <source> [--discard]` | Control a running job from another shell (see below). |
| `index jobs` | Running, paused, interrupted jobs with progress and ETA. |
| `index fetch-model` | Download the default embedding model into `models/embed/` (network; verified by SHA-256). Normal operation is offline. |

Common options: `--drive PATH` (repeatable, or `PROMETHEUS_DRIVES`) adds
other drives, `--device auto|cpu|cuda`, `--max-source-gb N` (skip bigger ZIMs,
they stay queued), `--priority low|normal` (low is the default),
`--allow-unverified` (tests only).

## Full build versus incremental update

* First time on a drive: `scripts/index build all` (add `--max-source-gb 5` to do
  the small sources first; run again later without the cap and finished ones
  are skipped). Do this on a GPU host.
* After a ZIM is replaced by the updater: `scripts/index update <source>`. An
  article is re-embedded only when the SHA-256 of its ZIM content changed.
* New embedding model, new chunking/extractor version or quantization change:
  `status` shows `model-mismatch`; run `scripts/index rebuild all`.

## What is stored (and not)

Per source, on **the same drive as the source ZIM**: `<drive>/index/<source>/`.

* `state.db`: sqlite (rollback journal, `synchronous=FULL`): meta, segment
  table with SHA-256s, article table (`path`, content hash, segment, row range).
* `seg-NNNNNN.vec`: int8 vectors (fixed scale 127 on L2-normalised floats).
* `seg-NNNNNN.rec`: 16-byte records: article id, chunk number, start, end.

No chunk text is stored. A hit is (article path, byte offsets, content hash);
text is obtained by reading the entry from the ZIM, running the deterministic
extractor (`extract.EXTRACTOR_VERSION`, recorded per index) and slicing the bytes.
PDF entries with a text layer are indexed through `pypdf`; PDFs without
text are counted as `needs_ocr_pdfs` and recorded without chunks.
`pypdf` needs `cryptography>=3.1` to open AES-encrypted PDFs; without it
those entries are skipped with `DependencyError`.

Embedding model: **bge-small-en-v1.5** (33 M parameters, 384-d, fp32 ONNX,
about 130 MB) in `models/embed/bge-small-en-v1.5/` (`embed.json`, `model.onnx`,
`tokenizer.json`). It fits an RTX 4070 Ti SUPER 16 GB with huge headroom and
also runs on CPU. CUDA is used through onnxruntime when available, otherwise the
CPU provider. fp32 is used on both so vectors do not depend on the device.
Size per chunk: 384 B vector + 16 B record (no HNSW graph: search is a
brute-force int8 scan, which is fine up to a few million chunks per source; add
an ANN structure or binary quantization + rerank before the largest sources).

## Crash safety, exFAT and locks

* exFAT has no symlinks, hardlinks or journal. Everything durable is written
  as temp file in the same directory, `fsync`, `os.replace`, directory `fsync`
  (skipped on Windows, which cannot open directories). Replace on exFAT is not
  guaranteed atomic through a power cut, so segments are immutable and checksummed
  and nothing relies on a rename alone.
* A **checkpoint** is one sqlite transaction that registers a finished segment,
  upserts the articles it covers and advances the cursor. Segment files are
  written and fsynced first; a crash before commit leaves an unregistered file
  that is removed on the next start, a crash after commit loses nothing.
* Resume = start the same command again. An in-progress run (`run_state=running`)
  continues from its cursor (same ZIM) with the same run generation; if the ZIM
  changed meanwhile the run restarts and article hashes keep unchanged work.
* A lock file per source, `<drive>/index/<source>.lock` (host, pid, heartbeat),
  created with `O_EXCL`. Locks of dead PIDs on this host, or older than
  `lock_stale_after_sec`, are taken over; a live lock from another host is
  respected and the source is skipped.
* Rebuild swap: `index/<source>` -> `.<source>.old`, `.<source>.rebuild` ->
  `index/<source>`, delete `.old`. A crash in between is repaired on the next run.
* An unplugged drive behaves like a crash: files are valid up to the last
  checkpoint; start the command again after replugging.

## Pause, resume, cancel (BAC-189)

* Ctrl-C or SIGTERM: finishes the current article, writes a checkpoint, exits
  with code 130. Rerun to resume.
* `index pause <source>` writes `<drive>/run/index-control/<source>.ctl`; the job
  checkpoints and idles (job state `paused`) until `index resume <source>`.
* `index cancel <source>` checkpoints and exits 3, keeping progress.
  `--discard` also deletes the partial work: a never-finished build or a partial
  rebuild directory. A finished index is never deleted by a cancel.
* Job state lives in `<drive>/run/index-jobs/<source>.json`; `index jobs` lists it.

## Host limits and logs

`config/host.conf` (per hostname, `[default]` otherwise) and `config/index.conf`
supply `index_device`, `index_threads`, `checkpoint_chunks`, `embed_batch`,
`lock_stale_after_sec`. Workers run at below-normal priority by default. Quiet
hours, market hours and temperature pauses from `host.conf` are not applied by
the indexer yet (follow-up); schedule it through the updater windows.
One log per run: `<drive>/run/logs/index/<timestamp>-<command>.log`. Unreadable
entries and PDFs without text are listed there and never abort the run.

## Safety rules

The indexer only reads `library/`, only indexes ZIMs that have a matching
`run/verified/<file>.verified.json` marker (size must match) and never writes
outside `index/`, `run/` and (via `fetch-model`) `models/embed/`.

## Install

```
python3 -m venv run/venv-index
run/venv-index/bin/pip install -r scripts/prometheus_index/requirements.txt   # Windows: run\venv-index\Scripts\pip
scripts/index fetch-model
```

That requirements file includes `cryptography>=3.1`, which `pypdf` needs
to open AES-encrypted PDFs, and `fonttools>=4.0`, which is part of the
extractor identity. A fresh host should install from that file rather than
picking packages by hand. `scripts/index` and `scripts/index.ps1` use the
venv but do not install dependencies themselves.

On a CUDA host use `onnxruntime-gpu` (plus the CUDA 12 / cuDNN 9 runtime, e.g. the
`nvidia-*-cu12` pip wheels) instead of `onnxruntime`. `scripts/index status` and
the log show which device was used.

## Not done yet

* Survivor Library (scanned PDFs): needs OCR and a sidecar text store; deferred
  via `defer_ocr`.
* `custom-additions/docs/` as a per-drive source (BAC-188, BAC-158).
* Picker/updater hooks, quiet hours / temperature pause, ANN or binary+rerank.

## Tests

```
python -m pip install pytest libzim numpy
python -m pytest tests/index -q
```
