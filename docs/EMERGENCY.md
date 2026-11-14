# Prometheus emergency README

You are holding an offline knowledge library. You do not need the
internet, a password, or this git history to use it.

## 1. Plug the drive in

The volume is labeled **PROMETHEUS** and is formatted exFAT, so
Windows, macOS, and Linux can all read it. Open that volume. The rest
of these commands are run from its top-level folder (the one that
contains `library/`, `apps/`, `scripts/`, and `docs/`).

## 2. Start the library first

This is the important step. The AI is optional and is not required to
read Wikipedia, medical references, Wikivoyage, and the rest of the
ZIM collection.

macOS / Linux:

```bash
./scripts/start-library.sh
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-library.ps1
```

If the script will not run, start kiwix by hand from this same folder:

```bash
# macOS / Linux
./apps/kiwix-serve --port 8080 --address 0.0.0.0 library/*.zim
```

```powershell
# Windows
& .\apps\kiwix-serve.exe --port 8080 --address 0.0.0.0 @(Get-ChildItem .\library\*.zim | ForEach-Object { $_.FullName })
```

Look in `apps/linux-x86_64/`, `apps/darwin-arm64/`, or
`apps/windows-x86_64/` if the binary is not at `apps/kiwix-serve`.

## 3. Browse

On this computer open <http://127.0.0.1:8080/>.

From another computer on the same network, open
`http://<this-computer's-address>:8080/`.

Maps, if present, are under `maps/` with a portable viewer; they do
not depend on the AI either.

## 4. Optionally start the AI

Only do this after the library page above loads. If the model fails or
the computer is too small, the library stays up.

Let the auto launcher pick a tier:

```bash
./scripts/start-auto.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-auto.ps1
```

Or start a tier by hand (`low`, `mid`, or `high`):

```bash
./scripts/start-ai.sh mid
```

Raw command, mid-tier example (after the library is already running):

```bash
./models/mid/model.llamafile --server --nobrowser --host 0.0.0.0 --port 8081
```

The model API, when healthy, is <http://127.0.0.1:8081/v1/models>.

## 5. Stop

```bash
./scripts/stop.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop.ps1
```

Or press Ctrl+C in each terminal you started by hand (AI first, then
the library). It is safe to run the stop script even if nothing is
running.

Then unplug the drive. (Later, BAC-155 will make in-progress updates
safe to interrupt; until then, prefer stopping the services first.)
