# Prometheus launcher and updater tests

These checks use tiny stub HTTP servers and policy overrides. They do
not download ZIMs, maps, or models, they do not touch a physical drive,
and they do not install a real crontab.

```bash
# From the repo root
./tests/dry-run.sh
./tests/update-dry-run.sh
```

`dry-run.sh` proves the Phase 3 start/stop contract:

- `stop.sh` succeeds when nothing is running (and with stale PID files)
- `start-auto.sh` starts kiwix-serve first, then llamafile
- a failing or missing AI leaves the library up
- `start-ai.sh` refuses to start unless the library is already healthy
- a failing RAG helper does not take kiwix-serve or llamafile down

`update-dry-run.sh` proves the portable updater (BAC-152):

- `scripts/update` finds the drive root from its own location
- `host.conf` selects the ZEUS weekend-night window versus the default nightly window
- a heat pause at about 75°C (80°C in the test) stops an update, even with `--force`, unless `--ignore-temp` is also passed
- a live lock from another host is left alone; stale locks (dead PID or expired heartbeat) are taken
- a read-only drive exits 0
- missing temperature sensors are skipped, not treated as a failure
- `start-auto` honors `library_only` and `skip_ai_when_hot`
- `install-schedule --dry-run` prints a plan and does not change crontab

Unix scripts are linted with ShellCheck (`shellcheck -s sh` for the
POSIX updater, `shellcheck -x -P SCRIPTDIR` for the bash launchers).
PowerShell scripts are included for Windows but are not executed on
the Linux box; run PSScriptAnalyzer on a Windows or `pwsh` machine
when one is available.

## Indexer tests (BAC-150 / BAC-188 / BAC-189)

```bash
python -m pip install pytest libzim numpy
python -m pytest tests/index -q
```

Build tiny ZIMs on the fly and cover atomic writes, locks, build, incremental
update (changed/new/deleted), crash then resume (and equality with a clean
build), interrupt/pause/resume/cancel, rebuild swap and failed rebuild,
interrupted-swap recovery, model-mismatch, and verify (corrupt, missing, orphan,
stale, bad database).
