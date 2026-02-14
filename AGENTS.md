# AGENTS

## Repo purpose
This repo contains `ecc-timelapse.zsh`: a Zsh script to generate/export timelapse videos (and related helpers/docs) for the ECC timelapse workflow.

## Safety invariants
- Local-only by default: do not add behavior that mutates remote systems (upload, delete, edit, or API calls) without explicit prior approval.
- Prefer safe defaults: require `--dry-run`/confirmation for any destructive local operations.

## Update process (when `ecc-timelapse.zsh` changes)
1. Bump the version in `ecc-timelapse.zsh`.
2. Update `CHANGELOG.md` (add a new version section; `CHANGELOG.md` currently starts at `0.1.0`).
3. Commit and push.

## Quick checks
- Syntax check: `zsh -n ecc-timelapse.zsh`
- Smoke test (no side effects): `./ecc-timelapse.zsh --dry-run --verbose`

## Git hygiene
- Do not commit runtime artifacts or outputs: `ecc/`, `*.mp4`.
