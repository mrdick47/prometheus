# Prometheus drive layout plan

This is the planned layout of the PROMETHEUS volume (exFAT, so Windows,
macOS, and Linux can all read it). The git repo is designed so its root
can be the drive root. Scripts never assume a drive letter (`I:`, `J:`),
a fixed Unix mount point, or a particular host (including ZEUS); they
locate the root from their own path, and per-host limits live in
`config/host.conf`.

Do not create this layout on a physical drive until BAC-140 is done
(copy verified, Richard's explicit OK, format as exFAT labeled
PROMETHEUS) and BAC-141 is in progress. The directories in this git
repo are documentation placeholders only.

## Directories

```
PROMETHEUS/                  # volume root, also the git repo root
  library/                   # Kiwix ZIM files (BAC-143)
  maps/                      # world OSM vector tiles + offline viewer (BAC-144)
  index/                     # one vector index (or subdirectory) per source (BAC-150)
  models/
    low/                     # ~3B llamafile / GGUF
    mid/                     # ~8B llamafile / GGUF
    high/                    # 14B–32B llamafile / GGUF
    embed/                   # embedding model (~500 MB or less)
  apps/                      # portable kiwix-serve, kiwix-desktop, llamafile
  iso/                       # reserved for a Linux ISO and offline installers (BAC-145)
  scripts/                   # start / stop / auto launcher
  config/prometheus.conf     # ports, paths, hardware thresholds
  config/host.conf           # optional per-host schedule and heat limits
  config/sources.conf        # catalog URLs (empty until Phase 2)
  docs/                      # emergency README and printable quick start
  run/                       # created at runtime: PID files, update.lock, logs (not in git)
  README.md
```

BAC-141 lists `library/`, `maps/`, `index/`, `models/{low,mid,high,embed}`,
`apps/`, `scripts/`, and `docs/`. `iso/` is added as a clearly named
location for BAC-145 (a current Linux ISO and offline installers) so
those files are not mixed into `library/` or `maps/`. `config/` and
`run/` are launcher support added in Phase 3.

## Expected sizes (from the project brief)

After Phases 2–3, roughly 680 GB used on a 1 TB drive, with about
300 GB of headroom. World OSM tiles are about 120 GB (Protomaps or
OpenMapTiles). World coverage can be pruned later if space runs short.

## What git tracks vs what lives only on the drive

Tracked: scripts, docs, config, and the README placeholders in each
data directory.

Not tracked (see `.gitignore`): `*.zim`, OSM tiles (`*.pmtiles`,
`*.mbtiles`, `*.pbf`), model files (`*.gguf`, `*.llamafile`, and similar
weights), ISOs, vector index data, and `run/`.

## Binary placement

Preferred locations, in the order the launcher searches:

1. `KIWIX_SERVE` / `LLAMAFILE` in `config/prometheus.conf` or the environment
2. `apps/kiwix-serve` or `apps/kiwix-serve.exe`
3. `apps/<os>-<arch>/kiwix-serve` where `<os>-<arch>` is one of
   `linux-x86_64`, `linux-aarch64`, `darwin-x86_64`, `darwin-arm64`,
   `windows-x86_64`
4. `apps/llamafile` or `apps/llamafile.exe`, then the same per-OS folders

A self-extracting `*.llamafile` under `models/<tier>/` is preferred for
the model itself. If only a `*.gguf` is present, the launcher uses the
llamafile runtime from `apps/`.

## Indexes

Phase 4 (BAC-150) builds one vector index per source under `index/`,
for example `index/wikipedia/`, `index/wikimed/`, `index/gutenberg/`.
Sources are not mixed into a single index. All three model tiers share
the same library and the same indexes; only the chat model changes.
