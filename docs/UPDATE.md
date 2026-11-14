# Prometheus self-updater (BAC-152)

The updater lives on the drive (`scripts/update` and `scripts/update.ps1`)
so any computer the drive is plugged into can keep the library current.
It is not tied to ZEUS, to a drive letter, or to a fixed mount path. ZEUS
is only the first always-on host, and its tighter limits live in
`config/host.conf`, not in the code.

This build installs the portable entry point, lock, host policy,
schedule installers, and hooks for catalog fetch / incremental
re-index / atomic swap. It does **not** download ZIMs, maps, or models
(Phase 2 will fill `config/sources.conf`). Run with `--download` and
`PROMETHEUS_ALLOW_DOWNLOAD=1` only after that catalog is reviewed.

## Entry point

From the drive root (any mount point or letter):

```bash
./scripts/update
./scripts/update --dry-run
./scripts/update --status
./scripts/update --force          # ignore the schedule window, still honor heat and the lock
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1 -DryRun
```

The script finds the drive root from its own location. If the drive is
missing or read-only, or another host already holds the lock, it exits
0 so a scheduled job stays quiet.

## Lock

`run/update.lock/` is a directory on the drive. It records hostname,
PID, and a heartbeat. Two hosts (or two runs) never update at once.

A lock is treated as stale, and replaced, when:

- it was taken on **this** host and the recorded PID is no longer running, or
- its heartbeat (or start time, if there is no heartbeat) is older than
  `lock_stale_after_sec` (default 6 hours).

A fresh lock from another host is left alone; the new run exits 0.

## host.conf

Optional `config/host.conf`, keyed by hostname (case-insensitive, short
name). When this machine has no section, `[default]` is used:

- nightly, low priority (`nice` 19, `ionice` idle)
- pause at about 75°C if a temperature reading is available; if it is
  not, the check is skipped and the update proceeds
- market hours are not blocked (that is a ZEUS / bacon-trader concern)

The bundled example ZEUS section is:

- weekend nights only (Friday 22:00 through Sunday 06:00 America/Chicago)
- never during US regular market hours (09:30–16:00 America/New_York)
- `nice` / `ionice` low priority
- pause at or above 75°C, reading Linux `coretemp` "Package id 0" when
  that sensor exists

The start/stop scripts honor `host.conf` where it makes sense:

- `library_only=1` keeps `start-auto` / `start-ai` on the library
- `skip_ai_when_hot=1` (default) skips the AI add-on at or above
  `pause_temp_c` and leaves the library up
- llamafile is launched with `nice` / `ionice` when those tools exist
- `--force` on the start scripts overrides those AI skips

Starting the library itself is never blocked by market hours or heat;
the library is the core service.

## Schedule installers

One line from the drive root (re-run if the usual mount path changes;
the wrapper also looks for a volume labeled `PROMETHEUS`):

```bash
./scripts/install-schedule              # Linux: user crontab; macOS: launchd
./scripts/install-schedule --systemd    # Linux systemd --user timer
./scripts/uninstall-schedule
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-schedule.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-schedule.ps1
```

The installer copies `scripts/run-scheduled-update` (or `.ps1`) off the
drive into a per-user location so the scheduled job can exit 0 when the
drive is unplugged instead of failing to find the script. The wrapper
then finds the volume (recorded path, `/Volumes/PROMETHEUS`,
`/dev/disk/by-label/PROMETHEUS`, or a Windows volume label) and runs
`scripts/update`.

For ZEUS, the installer writes a weekend-night window (hourly inside
22:00–06:00, wrapping midnight). For any other host, it writes the
nightly window from `[default]` (02:00–06:00). `scripts/update` itself
re-checks the window, market hours, heat, and "already updated today",
so an hourly job is safe.

### Raw cron lines

Replace `<wrapper>` with the installed
`~/.local/share/prometheus/run-update`, or with
`<drive>/scripts/update` if you prefer to call the drive directly (that
form errors in cron when the drive is unplugged; the wrapper does not).

Nightly, default host (02:00–05:00 local, every day):

```
0 2,3,4,5 * * * <wrapper>   # prometheus-update
```

Weekend nights, ZEUS-style (Fri–Sat 22:00–23:00, Sat–Sun 00:00–05:00):

```
0 22,23 * * 5,6 <wrapper>   # prometheus-update
0 0,1,2,3,4,5 * * 6,0 <wrapper>   # prometheus-update
```

A single Saturday 23:00 job also works; the hourly form lets a heat
pause retry later the same night.

### Raw schtasks line

Nightly at 03:00:

```
schtasks /Create /TN "PrometheusUpdate" /SC DAILY /ST 03:00 /TR "powershell -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\Prometheus\run-update.ps1"
```

Remove it with `schtasks /Delete /TN "PrometheusUpdate" /F`.

## What the updater will do once Phase 2 / 4 land

1. Check `config/sources.conf` for new Kiwix ZIMs (and later maps).
2. Download only the sources that changed, verify checksums.
3. Leave unrelated sources untouched.
4. Swap new files in atomically (`library/.incoming` → destination,
   keeping one previous copy under `library/.previous`).
5. Call `scripts/reindex --incremental --device gpu|cpu` when that hook
   exists. Heavy re-indexing uses a GPU if the host has one, otherwise
   a slow incremental CPU pass.

Until those hooks and catalog URLs exist, `scripts/update` still
enforces policy, takes the lock, and records `run/last-update`.
