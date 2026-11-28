# Prometheus

Prometheus is an offline "restart civilization" knowledge drive: a Kiwix
library, world OpenStreetMap tiles, and optional tiered llamafile models
with RAG. Plug the drive into a computer, start the library, and browse
without the internet.

This git repository holds the scripts, launcher, indexer notes, and docs.
It is completely separate from bacon-trader. Large data files (ZIM
archives, map tiles, model weights, vector indexes, ISOs) are not stored
in git; they live on the PROMETHEUS drive.

## Drive layout

The repository root is meant to sit at the root of the PROMETHEUS drive
(or be copied there). Scripts resolve the drive root from their own
location, so they work from any Windows drive letter or any Unix mount
point. See [docs/LAYOUT.md](docs/LAYOUT.md) for the full plan.

| Path | Purpose |
| --- | --- |
| `library/` | Kiwix ZIM files |
| `maps/` | World OpenStreetMap ready-to-view vector tiles and a portable offline viewer |
| `index/` | One vector index (or subdirectory) per source |
| `models/low` | Small llamafile / GGUF (~3B) for laptops and old PCs |
| `models/mid` | Mid llamafile / GGUF (~8B) |
| `models/high` | Large llamafile / GGUF (14B–32B) for a gaming PC and GPU |
| `models/embed` | Embedding model for RAG |
| `apps/` | Portable `kiwix-serve`, `kiwix-desktop`, and llamafile runtime |
| `iso/` | Linux ISO and offline installers (reserved; see BAC-145) |
| `scripts/` | Auto and manual start/stop scripts |
| `config/prometheus.conf` | Ports, paths, and hardware thresholds |
| `config/host.conf` | Optional per-host schedule, nice/ionice, and heat limits |
| `docs/` | Emergency README and printable one-page quick start |
| `run/` | PID files and logs (created at runtime, not checked in) |

World map coverage can be pruned later if the 1 TB drive runs short of
space. After Phases 2–3, expect roughly 680 GB used and about 300 GB of
headroom.

## Host the library first; AI is an add-on

`kiwix-serve` always starts first and is the core service. The AI
(llamafile, then optional RAG) starts only after the library answers an
HTTP health check. If the machine is too weak to run a model, a model
file is missing, or the AI process crashes, the library stays up.

Default URLs (see `config/prometheus.conf`; these ports are defaults,
not values from the Linear cards):

- Library: <http://127.0.0.1:8080/>
- llamafile API: <http://127.0.0.1:8081/v1/models>
- Optional RAG: <http://127.0.0.1:8082/> (disabled until a server path is set)

From another computer on the same network, replace `127.0.0.1` with the
host computer's address. Services bind to `0.0.0.0` by default.

## Scripts

Unix scripts (`.sh`) run on macOS and Linux. Windows scripts (`.ps1`)
are PowerShell. All paths they use are relative to the drive root.

A clone from GitHub does not preserve executable bits. On Linux and
macOS, run `chmod +x scripts/*` after cloning, or run the scripts
via `sh` or `bash` (for example `sh scripts/start-library.sh`).

| Script | What it does |
| --- | --- |
| `scripts/start-library.sh` / `scripts/start-library.ps1` | Start kiwix-serve only |
| `scripts/start-ai.sh` / `scripts/start-ai.ps1` | Start llamafile (and RAG if configured) after the library is healthy. Pass `low`, `mid`, or `high` to pick a tier. |
| `scripts/start-auto.sh` / `scripts/start-auto.ps1` | Start the library first, then pick the best llamafile tier from RAM and GPU and start it. Falls back to library-only. |
| `scripts/clone-drive` / `scripts/clone-drive.ps1` | Copy finished vector indexes (and optionally ZIMs) to another drive with checksums, resumable, `--plan` first. See [docs/INDEX.md](docs/INDEX.md). |
| `scripts/stop.sh` / `scripts/stop.ps1` | Stop the AI (if any) then the library. Safe to run when nothing is running. |

On Windows, if script execution is blocked:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-library.ps1
```

## Raw commands

If the scripts will not run, start the programs by hand from the drive
root. Adjust binary names and model filenames to match what is actually
on the drive. Full copies of these commands, including stop hints, are
in [docs/README.md](docs/README.md) and [docs/EMERGENCY.md](docs/EMERGENCY.md).

### Windows (PowerShell)

```powershell
# Library
.\apps\kiwix-serve.exe --port 8080 --address 0.0.0.0 (Get-ChildItem .\library\*.zim | ForEach-Object { $_.FullName })

# AI (example: mid tier llamafile). Start this only after the library is up.
.\models\mid\model.llamafile --server --nobrowser --host 0.0.0.0 --port 8081
```

### macOS and Linux

```bash
# Library
./apps/kiwix-serve --port 8080 --address 0.0.0.0 library/*.zim

# AI (example: mid tier llamafile). Start this only after the library is up.
./models/mid/model.llamafile --server --nobrowser --host 0.0.0.0 --port 8081
```

If a platform-specific binary is under `apps/linux-x86_64/`,
`apps/darwin-arm64/`, or `apps/windows-x86_64/`, use that path instead.
Stop a hand-started process with Ctrl+C in its terminal, or close that
window.

## Auto tier selection

The auto launcher (BAC-147) picks one shared library and search index
and only changes the model:

- **High** — discrete GPU (or plenty of unified memory on Apple Silicon)
  and at least 32 GB RAM; Qwen 14B–32B class.
- **Mid** — at least 16 GB RAM, or a discrete/modest GPU with at least
  8 GB RAM; Qwen ~8B class.
- **Low** — about 8 GB RAM, typically CPU-only; Qwen or Llama ~3B class.
- **Library only** — less than 8 GB RAM, no usable model file, or the
  chosen model fails to become healthy.

If the preferred tier has no model file, the launcher walks down to a
smaller tier before giving up.

## Self-updater (any host)

The updater lives on the drive, not on a particular computer. ZEUS is
only the first always-on host; its tighter weekend-night and heat
limits are in `config/host.conf`, not hardcoded.

```bash
./scripts/update              # POSIX sh, macOS and Linux
./scripts/update --dry-run
./scripts/install-schedule    # cron, systemd --user, or launchd
./scripts/uninstall-schedule
```

```powershell
.\scripts\update.ps1
.\scripts\install-schedule.ps1
```

`run/update.lock/` prevents two hosts from updating at once and treats
a dead or expired lock as stale. If the drive is unplugged or
read-only, the job exits 0. Full details, including raw cron and
schtasks lines, are in [docs/UPDATE.md](docs/UPDATE.md).

## Repository hosting

This repo is local only for now, initialized at
`/workspace/prometheus`. **BAC-142 does not name a GitHub organization,
account, or visibility.** Do not create a GitHub (or other) remote until
Richard approves where it should live and whether it is public or
private.

No license file is included: none of BAC-140–BAC-157 names a license.

## Phases (Linear project)

Tracked in the [Prometheus Linear project](https://linear.app/bacon-lab/project/prometheus-ecc96b9a459b)
(BAC-140–BAC-157):

1. Prep the drive (verify the existing copy, get Richard's explicit OK,
   format as exFAT labeled PROMETHEUS, folder layout, create this repo)
2. Fill the library (Kiwix ZIMs, world OSM, Linux ISO)
3. Launcher and models (this repo's start/stop scripts; library first)
4. Index on POSEIDON (one-time GPU build, incremental hashes, eval)
5. Upkeep on whatever host the drive is plugged into (portable
   Saturday-night or nightly job, monthly health note, quarterly
   model check). ZEUS is the first always-on host, not the only one.
6. Grab-and-go readiness (atomic updates or rollback, printed quick start,
   later offsite copy)

Do not format or write a physical drive from this repository's tools.
Phase 1 formatting is a separate, explicit-OK step (BAC-140).
