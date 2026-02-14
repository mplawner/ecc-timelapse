# Contributing

Thanks for taking the time to contribute.

## Ground Rules

- Keep changes focused and easy to review.
- Safety first: do not introduce any behavior that mutates remote state. Remote
  interactions must remain read-only (capability probes, listing, and copying
  data to local only).
- Prefer conservative, portable shell code (Zsh); avoid unnecessary dependencies.

## Quick Checks

Run these before opening a PR:

```sh
zsh -n ecc-timelapse.zsh
./ecc-timelapse.zsh --dry-run --verbose
```

Notes:

- `--dry-run` is offline by design: it must not perform any network actions and
  must not create local directories.

## Reporting Bugs

If you open an issue, include:

- what you expected to happen
- what actually happened
- your OS + Zsh version
- the command you ran (and whether `--dry-run` was used)
- relevant logs/output (redact hostnames, usernames, and paths as needed)

## Pull Requests

- Describe the motivation and the user-facing behavior change.
- Keep PRs small; split refactors from behavior changes when possible.
- If you add or change flags/output, update `README.md` and `--help` text to match.
- Avoid changes that would commit local runtime artifacts (anything under `./ecc/`).

## Development Notes

Project structure is intentionally minimal:

- `ecc-timelapse.zsh`: the script (single entrypoint)
- `README.md`: usage and behavior documentation
