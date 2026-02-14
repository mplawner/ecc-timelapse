# ECC Timelapse (sync + render + prune)

`ecc-timelapse.zsh` is a single-entrypoint Zsh script that:

- syncs per-print timelapse frame folders from an Elegoo printer/controller over SSH into a local workspace
- renders each folder into an H.264 MP4 using `ffmpeg`
- (optionally) prunes local frame folders after a successful render

It is designed to be:

- safe: it never deletes or modifies remote files
- idempotent: it records processed folders locally and skips already-rendered prints
- conservative: uses simple transports (`rsync` when available, else `tar` stream, else `scp`)

Assumptions

- SSH host alias: `elegoo` (override with `ECC_HOST`)
- Remote directory: `/user-resource/aic_tlp` (override with `ECC_REMOTE_DIR`)
- You typically run it when the printer is *not actively printing* (so the remote folder contents are stable)

## What it does

By default (no mode flag), it runs the full pipeline:

1. Sync: list remote per-print directories and download any that are not already rendered.
2. Render: render local per-print directories into MP4s.
3. Prune (local): once a print is considered processed (rendered MP4 exists and validates), delete `./ecc/incoming/<print-folder>/` unless `--keep-frames` is set.

Optional mode flags let you run one stage at a time:

1. `--sync-only`: run only the sync stage.
2. `--render-only`: run only the render+prune stage (prune is skipped with `--keep-frames`).

## Requirements

Local machine:

- `zsh`
- `ssh` and either `rsync` (preferred), or `tar`, or `scp`
- `ffmpeg` (and `ffprobe`, typically included with ffmpeg)

Remote (printer/controller):

- SSH access
- Any POSIX-ish `sh`
- Optional: `rsync` or `tar` (script will fall back automatically)

## Setup

1. Make the script executable:

```sh
chmod +x ecc-timelapse.zsh
```

2. Ensure SSH connectivity (key-based auth recommended). Example `~/.ssh/config`:

```sshconfig
Host elegoo
  HostName <printer-ip-or-hostname>
  User root
  IdentityFile ~/.ssh/id_ed25519
```

3. Optional environment overrides:

```sh
export ECC_HOST=elegoo
export ECC_REMOTE_DIR=/user-resource/aic_tlp
export FRAMERATE=30
```

## Usage

Show help:

```sh
./ecc-timelapse.zsh --help
```

Default end-to-end run (sync + render + prune):

```sh
./ecc-timelapse.zsh
```

Notes:

- This default run prunes local incoming frames once a print is considered processed unless you pass `--keep-frames`.
- `--dry-run` is offline: it forbids all network actions (it will not SSH and will not sync from the printer/controller).

Optional split run (sync only, then render only):

```sh
./ecc-timelapse.zsh --sync-only
./ecc-timelapse.zsh --render-only
```

### Examples (exact flags supported)

List remote per-print directories (one name per line):

```sh
./ecc-timelapse.zsh --list-remote
```

Sync everything (skips already-rendered prints):

```sh
./ecc-timelapse.zsh --sync-only
```

Sync a single remote folder:

```sh
./ecc-timelapse.zsh --sync-only --print "My Print Folder"
```

Render everything currently under `./ecc/incoming/`:

```sh
./ecc-timelapse.zsh --render-only
```

Render a single print folder under `./ecc/incoming/`:

```sh
./ecc-timelapse.zsh --render-only --print "My Print Folder"
```

Render one arbitrary local directory (no SSH at all):

```sh
./ecc-timelapse.zsh --render-only --input "/path/to/frames-dir"
```

Dry-run with verbose logging (no network access, no directory creation):

```sh
./ecc-timelapse.zsh --dry-run --verbose
./ecc-timelapse.zsh --dry-run --verbose --sync-only
./ecc-timelapse.zsh --dry-run --verbose --render-only
```

Print resolved paths and derived output naming for one remote folder:

```sh
./ecc-timelapse.zsh --print "My Print Folder"
```

Pick one folder and print naming:

```sh
./ecc-timelapse.zsh --print-one
```

Notes on `--print-one`:

- without a mode, it queries the remote and selects the first remote print folder
- in `--render-only`, it selects the lexicographically-first local folder under `./ecc/incoming/`
- it is not available under `--dry-run` (because it requires remote listing)

## Local directory layout

The script resolves paths relative to its own directory (not your current working directory) and creates the following lazily under `./ecc/`:

```text
./ecc/
  incoming/           Synced frames, one subdir per print folder
  output/             Rendered MP4 files
  state/
    lock/             Run lock (prevents concurrent runs)
    manifest/         Per-print metadata (hashed filenames, TSV)
  logs/               Reserved for future logging
  work/               Scratch space used during rendering
```

## Output naming

Rendered videos go to:

```text
./ecc/output/<YYYY-MM-DD>_<print-folder>.mp4
```

Where `<print-folder>` is the *remote* per-print directory name.

The date prefix is derived as:

- default (remote-based): query the remote print folder timestamp and derive `YYYY-MM-DD`
- `--render-only --input <dir>`: derive `YYYY-MM-DD` from the local directory mtime

## Safety guarantees

- Remote is read-only: remote actions are limited to capability probes and directory listing, plus transferring files to local.
- No remote deletion: the script never runs `rm` on the remote host and never attempts to mutate remote contents.
- Dry-run is offline: `--dry-run` forbids all network actions (so it will not sync from the printer/controller) and avoids creating directories; it prints what would be executed.
- Local prune is guarded: local frame pruning only deletes directories under `./ecc/incoming/` and refuses unsafe paths.

## How idempotency works (manifest)

For each print folder, the script writes a small TSV manifest in `./ecc/state/manifest/` (filename is a SHA-256 of the print folder name). It records:

- `remote_folder`
- `derived_date`
- `output_filename`
- `processed` (1 when a valid MP4 exists)

If `processed=1` and the MP4 validates via `ffprobe`, that print folder is treated as already rendered:

- `--sync-only` skips downloading it again
- `--render-only` skips rendering it again; if local frames exist and `--keep-frames` is not set, they are pruned

## Remote timestamp derivation (BusyBox-friendly)

To compute the `YYYY-MM-DD` prefix for a remote print folder, the script runs a remote command like:

- `ls -ld --full-time --time=birth -- <dir>` (preferred)
- falls back to `ls -ld --full-time -- <dir>` if birthtime is not supported (common on BusyBox)

It then parses only the fixed-position date/time fields using a remote `read` loop (and intentionally ignores the filename field), so spaces in print folder names are safe.

## Troubleshooting

- "unknown argument": run `./ecc-timelapse.zsh --help` and use only documented flags (no positional args are accepted).
- "ffmpeg not found": install ffmpeg and ensure `ffmpeg` is on `PATH`.
- "render produced invalid mp4": check that the input folder contains `tlp_layer_<n>` frame files and that `ffprobe` can read the produced file.
- "another run is already in progress": a lock exists at `./ecc/state/lock/`. If a previous run crashed, remove the lock directory manually once you're sure nothing is running.
- SSH failures: verify `ECC_HOST`, your `~/.ssh/config`, and that the remote accepts key auth (`ssh -o BatchMode=yes elegoo true`).

## Notes on `--force`

`--force` currently affects sync behavior when the local incoming directory already exists:

- `tar` / `scp` transports: if `./ecc/incoming/<print-folder>/` exists, sync is skipped unless `--force` is set
- `rsync` transport: rsync updates the destination regardless (it does not use the local-exists shortcut)

The flag is also reserved for future state/refresh behaviors.

## Reference

CLI synopsis (from `--help`):

```text
./ecc-timelapse.zsh [--dry-run] [--keep-frames] [--force] [--verbose] [--sync-only|--render-only] [--list-remote] [--print <remote-folder>|--print-one] [--input <local-dir>]
```
