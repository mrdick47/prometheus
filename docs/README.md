# Prometheus docs

Operator documentation for the PROMETHEUS drive. Start with
[EMERGENCY.md](EMERGENCY.md) if you just plugged the drive into an
unfamiliar computer. The one-page [QUICKSTART.md](QUICKSTART.md) is the
printable sheet (BAC-156; print and tape it to the drive later).

The layout plan is in [LAYOUT.md](LAYOUT.md). The portable
self-updater (any host, ZEUS as the first example) is documented in
[UPDATE.md](UPDATE.md). The indexer (`scripts/index`) is documented in
[INDEX.md](INDEX.md).

## Manual start and stop

Use these scripts from the drive root, or double-click the Windows
ones if PowerShell is allowed to run.

| Goal | macOS / Linux | Windows |
| --- | --- | --- |
| Library only | `./scripts/start-library.sh` | `powershell -ExecutionPolicy Bypass -File .\scripts\start-library.ps1` |
| AI only (pick a tier) | `./scripts/start-ai.sh mid` | `powershell -ExecutionPolicy Bypass -File .\scripts\start-ai.ps1 -Tier mid` |
| Auto (library first, then best tier) | `./scripts/start-auto.sh` | `powershell -ExecutionPolicy Bypass -File .\scripts\start-auto.ps1` |
| Stop everything | `./scripts/stop.sh` | `powershell -ExecutionPolicy Bypass -File .\scripts\stop.ps1` |

`start-ai` refuses to start if the library is not already healthy. It
does not start or stop kiwix-serve. Valid tiers are `low`, `mid`, and
`high`. `stop` is safe to run when nothing is running: it exits
successfully after cleaning any stale PID files.

Then browse:

- Library: <http://127.0.0.1:8080/>
- llamafile: <http://127.0.0.1:8081/v1/models>

## Raw commands if the scripts will not run

Run these from the drive root (the folder that contains `library/` and
`apps/`). Binary and model filenames on a finished drive may differ;
substitute what you actually see.

### Start the library (kiwix-serve)

Windows (cmd or PowerShell):

```text
apps\kiwix-serve.exe --port 8080 --address 0.0.0.0 library\*.zim
```

If `library\*.zim` does not expand in cmd, list the `.zim` files
instead, or use PowerShell:

```powershell
& .\apps\kiwix-serve.exe --port 8080 --address 0.0.0.0 @(Get-ChildItem .\library\*.zim | ForEach-Object { $_.FullName })
```

macOS and Linux:

```bash
./apps/kiwix-serve --port 8080 --address 0.0.0.0 library/*.zim
```

If there is no `apps/kiwix-serve`, look under `apps/windows-x86_64/`,
`apps/darwin-arm64/`, `apps/darwin-x86_64/`, or `apps/linux-x86_64/`.
Open <http://127.0.0.1:8080/> when it is up. Leave this process running.

### Start the AI (only after the library is up)

Windows:

```text
models\mid\model.llamafile --server --nobrowser --host 0.0.0.0 --port 8081
```

macOS and Linux (you may need `chmod +x` on the llamafile the first time):

```bash
./models/mid/model.llamafile --server --nobrowser --host 0.0.0.0 --port 8081
```

To use a different tier, replace `mid` with `low` or `high`. If you
have a `.gguf` file instead of a `.llamafile`, run the runtime from
`apps/`:

```bash
./apps/llamafile -m models/mid/model.gguf --server --nobrowser --host 0.0.0.0 --port 8081
```

Open <http://127.0.0.1:8081/v1/models> to confirm the API is up. The
library does not depend on this step.

### Stop

If you started the programs in terminals, press Ctrl+C in each one (AI
first, then the library). If you used the scripts, run `scripts/stop.sh`
or `scripts/stop.ps1`. Those scripts use PID files under `run/` and
HTTP health checks; they succeed even if nothing is running.

## Ports

Defaults in `config/prometheus.conf`:

| Service | Port |
| --- | --- |
| kiwix-serve | 8080 |
| llamafile | 8081 |
| optional RAG | 8082 (off unless `RAG_SERVER` is set) |

The Linear cards do not specify ports; these are documented defaults.
