# Prometheus — one-page quick start

*Placeholder for BAC-156 (print this and tape it to the drive).*

**Volume:** PROMETHEUS (exFAT). Open the drive and work from its top folder.

**Start the library (required)**

- macOS / Linux: `./scripts/start-library.sh`
- Windows: `powershell -ExecutionPolicy Bypass -File .\scripts\start-library.ps1`
- Hand start, if scripts fail: `apps/kiwix-serve --port 8080 --address 0.0.0.0 library/*.zim` (add `.exe` on Windows)

**Browse**

- On this computer: http://127.0.0.1:8080/
- On another computer on the same network: http://<this-computer's-address>:8080/

**Optional AI** (only after the library page loads; a failure will not take the library down)

- Auto: `./scripts/start-auto.sh` or `scripts\start-auto.ps1`
- Pick a tier: `./scripts/start-ai.sh mid` (or `low` / `high`)
- Hand start: `models/mid/model.llamafile --server --nobrowser --host 0.0.0.0 --port 8081`
- API: http://127.0.0.1:8081/v1/models

**Stop**

- `./scripts/stop.sh` or `scripts\stop.ps1` (safe if nothing is running)
- Or Ctrl+C in each terminal, AI first.

**Maps** live in `maps/` with a portable viewer and do not need the AI.
