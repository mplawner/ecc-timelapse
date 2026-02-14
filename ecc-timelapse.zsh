#!/bin/zsh

# ecc-timelapse.zsh
#
# Single entrypoint for the ECC timelapse pipeline.
# This task defines the CLI + local directory layout only.

emulate -L zsh

# Preserve arguments: `set -euo pipefail` in zsh will clobber $@ by treating
# `pipefail` as a positional parameter.
typeset -a ORIG_ARGS
ORIG_ARGS=("$@")

set -euo pipefail
setopt PIPE_FAIL
setopt NULL_GLOB
IFS=$'\n\t'
set -- "${ORIG_ARGS[@]}"

PROG="${0:t}"

usage() {
  cat <<'EOF'
Usage:
  ./ecc-timelapse.zsh [--dry-run] [--keep-frames] [--force] [--verbose] [--sync-only|--render-only] [--list-remote] [--print <remote-folder>|--print-one] [--input <local-dir>]

Local layout (created lazily under ./ecc/):
  ./ecc/incoming   - synced frames (future)
  ./ecc/output     - rendered mp4s (future)
  ./ecc/state      - cursors/checkpoints (future)
  ./ecc/logs       - logs (future)
  ./ecc/work       - scratch/temp work (future)

Environment variables (defaults shown):
  ECC_HOST=elegoo
  ECC_REMOTE_DIR=/user-resource/aic_tlp
  FRAMERATE=30

Flags:
  --help            Show this help and exit
  --dry-run         Print what would be done; do not create directories
  --keep-frames     Do not delete ./ecc/incoming/<print-folder>/ after a successful render
  --force           Allow overwriting/refreshing state (placeholder)
  --verbose         Verbose logging
  --print <folder>  Print resolved paths/output naming for a remote folder; with --sync-only, limit sync to this folder
  --print-one       Without a mode: pick one remote folder and print resolved naming (non-destructive)
  --list-remote     Print remote per-print directory names (one per line)
  --sync-only       Sync remote -> local under ./ecc/incoming/
  --render-only     Render local frames under ./ecc/incoming/ into ./ecc/output/
  --input <dir>     Render a single local directory (no SSH). Output name uses basename(<dir>).

Notes:
  - Default (no mode flag): runs sync then render.
  - Remote actions are read-only (capability probe + directory listing) and are skipped in --dry-run.
  - Script paths are resolved relative to the script directory, not caller CWD.
  - In --render-only --input mode, the date prefix is derived from the local directory mtime (macOS: stat -f %m; formatted via date -r).
  - In --render-only mode, --print/--print-one select local folders under ./ecc/incoming/ (date prefix still comes from the remote unless --input is used).
  - In --render-only mode (without --input), incoming frame directories are pruned after a successful render unless --keep-frames is set.
EOF
}

die() {
  print -ru2 -- "$PROG: error: $*"
  exit 2
}

log() {
  if (( VERBOSE )); then
    print -ru2 -- "$PROG: $*"
  fi
}

print_argv_quoted() {
  # Print args as a single, shell-escaped line (no trailing newline).
  # Avoid command substitution here: zsh + `set -euo pipefail` can clobber
  # positional parameters inside `$(func "$@")`.
  local first=1
  local a
  for a in "$@"; do
    if (( first )); then
      print -rn -- "${a:q}"
      first=0
    else
      print -rn -- " ${a:q}"
    fi
  done
}

run_cmd() {
  emulate -L zsh
  if (( DRY_RUN )); then
    print -rn -- "$PROG: dry-run: "
    print_argv_quoted "$@"
    print -r -- ""
    return 0
  fi
  if (( VERBOSE )); then
    print -rn -u2 -- "$PROG: exec: "
    print_argv_quoted "$@" >&2
    print -u2 -- ""
  fi
  "$@"
}

validate_print_folder_name() {
  emulate -L zsh
  local name="$1"
  [[ -n "$name" ]] || die "print folder name is empty"
  [[ "$name" != "." && "$name" != ".." ]] || die "invalid print folder name: $name"
  [[ "$name" != *$'\0'* ]] || die "invalid print folder name (NUL byte)"
  [[ "$name" != */* ]] || die "invalid print folder name (contains '/'): $name"
}

sh_single_quote() {
  # Return a POSIX-sh single-quoted string representing $1.
  # Example: abc'd -> 'abc'\''d'
  emulate -L zsh
  local s="$1"

  local out="'"
  local i ch
  for (( i = 1; i <= ${#s}; i++ )); do
    ch="${s[i]}"
    if [[ "$ch" == "'" ]]; then
      out+="'\\''"
    else
      out+="$ch"
    fi
  done
  out+="'"
  print -r -- "$out"
}

escape_remote_shell_word() {
  # Best-effort backslash escaping for remote shells (used for scp path args).
  # This is intentionally conservative; it is not a general-purpose quoting
  # function for arbitrary remote commands.
  emulate -L zsh
  local s="$1"
  s=${s//\\/\\\\}
  s=${s// /\\ }
  s=${s//\'/\\\'}
  s=${s//\"/\\\"}
  s=${s//\$/\\\$}
  s=${s//\`/\\\`}
  print -r -- "$s"
}

ssh_remote() {
  emulate -L zsh
  local host="$1"
  shift

  if (( DRY_RUN )); then
    die "internal: attempted network action during --dry-run"
  fi

  # Keep ssh behavior simple and rely on ~/.ssh/config for host aliases.
  ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$@"
}

remote_has_cmd() {
  emulate -L zsh
  local host="$1"
  local cmd="$2"

  local cmd_q="${cmd:q}"
  ssh_remote "$host" "sh -eu -c 'command -v \"\$1\" >/dev/null 2>&1' _ ${cmd_q}"
}

remote_require_dir() {
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"

  local remote_dir_q="${remote_dir:q}"
  if ! ssh_remote "$host" "sh -eu -c 'test -d \"\$1\"' _ ${remote_dir_q}"; then
    die "remote dir not found or not a directory: ${host}:${remote_dir}"
  fi
}

remote_supports_stat_mtime_epoch() {
  emulate -L zsh
  local host="$1"
  local remote_path="$2"

  local remote_path_q="${remote_path:q}"
  ssh_remote "$host" "sh -eu -c 'stat -c %Y -- \"\$1\" >/dev/null 2>&1' _ ${remote_path_q}"
}

pick_transport() {
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"

  if (( DRY_RUN )); then
    # No remote probe allowed in dry-run; pick a best-effort local guess so the
    # dry-run output shows the likely sync commands.
    if command -v rsync >/dev/null 2>&1; then
      print -r -- "rsync"
    elif command -v tar >/dev/null 2>&1; then
      print -r -- "tar"
    else
      print -r -- "scp"
    fi
    return 0
  fi

  remote_require_dir "$host" "$remote_dir"

  local have_rsync_local=0
  local have_tar_local=0
  local have_rsync_remote=0
  local have_tar_remote=0
  local stat_mtime_epoch=0

  command -v rsync >/dev/null 2>&1 && have_rsync_local=1
  command -v tar >/dev/null 2>&1 && have_tar_local=1

  remote_has_cmd "$host" rsync >/dev/null 2>&1 && have_rsync_remote=1
  remote_has_cmd "$host" tar >/dev/null 2>&1 && have_tar_remote=1
  remote_supports_stat_mtime_epoch "$host" "$remote_dir" >/dev/null 2>&1 && stat_mtime_epoch=1

  log "remote probe: rsync(local=$have_rsync_local,remote=$have_rsync_remote) tar(local=$have_tar_local,remote=$have_tar_remote) stat_mtime_epoch=$stat_mtime_epoch"

  if (( have_rsync_local && have_rsync_remote )); then
    print -r -- "rsync"
  elif (( have_tar_local && have_tar_remote )); then
    print -r -- "tar"
  else
    print -r -- "scp"
  fi
}

remote_list_print_dirs() {
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"

  if (( DRY_RUN )); then
    log "dry-run: would list remote directories under ${host}:${remote_dir}"
    return 0
  fi

  local remote_dir_q="${remote_dir:q}"
  local remote_cmd
  remote_cmd="sh -eu -c 'remote_dir=\"\$1\"; test -d \"\$remote_dir\"; for d in \"\$remote_dir\"/*/; do [ -d \"\$d\" ] || continue; d=\"\${d%/}\"; printf '\''%s\\0'\'' \"\${d##*/}\"; done' _ ${remote_dir_q}"

  if ! ssh_remote "$host" "$remote_cmd" | { while IFS= read -r -d $'\0' name; do print -r -- "$name"; done; true; }; then
    local -a ps
    ps=("${pipestatus[@]}")
    die "remote listing failed (ssh exit ${ps[1]:-?})"
  fi
}

maybe_mkdir_p() {
  local dir="$1"
  if (( DRY_RUN )); then
    print -r -- "$PROG: dry-run: mkdir -p -- $dir"
    return 0
  fi
  mkdir -p -- "$dir"
}

safe_prune_incoming_dir() {
  # Delete a local per-print incoming directory after successful render.
  # Guardrails:
  # - only delete directories underneath $INCOMING_DIR
  # - refuse to delete $INCOMING_DIR itself
  # - refuse empty/unsafe paths
  emulate -L zsh
  local dir="$1"
  [[ -n "$dir" ]] || die "refuse to prune empty path"
  [[ -d "$dir" ]] || die "refuse to prune (not a directory): $dir"

  local incoming_abs dir_abs
  incoming_abs="${INCOMING_DIR:A}"
  dir_abs="${dir:A}"
  [[ -n "$incoming_abs" ]] || die "internal: incoming dir resolved to empty"
  [[ -n "$dir_abs" ]] || die "refuse to prune (resolved to empty path): $dir"

  [[ "$dir_abs" != "/" ]] || die "refuse to prune root directory"
  [[ "$incoming_abs" != "/" ]] || die "internal: incoming dir resolved to root (unsafe)"

  if [[ "$dir_abs" == "$incoming_abs" ]]; then
    die "refuse to prune incoming root: $dir_abs"
  fi
  if [[ "$dir_abs" != "$incoming_abs"/* ]]; then
    die "refuse to prune outside incoming dir: $dir_abs (incoming=$incoming_abs)"
  fi

  run_cmd rm -rf -- "$dir"
  if (( DRY_RUN == 0 )); then
    log "prune: removed $dir_abs"
  fi
}

ensure_local_layout() {
  maybe_mkdir_p "$BASE_DIR"
  maybe_mkdir_p "$INCOMING_DIR"
  maybe_mkdir_p "$OUTPUT_DIR"
  maybe_mkdir_p "$STATE_DIR"
  maybe_mkdir_p "$MANIFEST_DIR"
  maybe_mkdir_p "$LOGS_DIR"
  maybe_mkdir_p "$WORK_DIR"
}

STATE_LOCK_ACQUIRED=0

release_state_lock() {
  emulate -L zsh
  (( STATE_LOCK_ACQUIRED )) || return 0
  local lock_dir="$STATE_DIR/lock"

  rm -rf -- "$lock_dir" >/dev/null 2>&1 || true
  STATE_LOCK_ACQUIRED=0
}

acquire_state_lock_or_die() {
  # Non-dry-run only: enforce single active sync/render execution.
  emulate -L zsh
  (( DRY_RUN )) && return 0

  mkdir -p -- "$STATE_DIR" || die "failed to create state dir: $STATE_DIR"

  local lock_dir="$STATE_DIR/lock"
  local meta_path="$lock_dir/meta.tsv"

  # Atomic lock acquisition: mkdir either creates or fails if it exists.
  if mkdir -- "$lock_dir" 2>/dev/null; then
    STATE_LOCK_ACQUIRED=1
    {
      print -r -- $'pid\t'"$$"
      print -r -- $'started_at_utc\t'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      print -r -- $'mode\t'"$MODE"
      print -r -- $'argv\t'"${(j: :)${(q)ORIG_ARGS[@]}}"
    } >| "$meta_path"
    trap release_state_lock EXIT INT TERM HUP
    return 0
  fi

  local msg="another run is already in progress (lock exists: $lock_dir)"
  if [[ -f "$meta_path" ]]; then
    local pid started mode
    pid="$(manifest_get_value "$meta_path" pid 2>/dev/null || true)"
    started="$(manifest_get_value "$meta_path" started_at_utc 2>/dev/null || true)"
    mode="$(manifest_get_value "$meta_path" mode 2>/dev/null || true)"
    [[ -n "$pid" ]] && msg+=" pid=$pid"
    [[ -n "$started" ]] && msg+=" started_at_utc=$started"
    [[ -n "$mode" ]] && msg+=" mode=$mode"
  fi
  print -ru2 -- "$PROG: $msg"
  exit 3
}

sha256_hex() {
  # Print a stable sha256 hex digest for $1.
  emulate -L zsh
  local s="$1"

  if command -v shasum >/dev/null 2>&1; then
    local out hash
    out="$(print -rn -- "$s" | shasum -a 256)"
    out="${out%%$'\n'*}"

    # `shasum -a 256` prints: `<hash>  -`
    # Do NOT rely on whitespace splitting: global IFS is set to $'\n\t'.
    hash="${out[1,64]}"
    hash="${hash:l}"
    if (( ${#hash} != 64 )) || [[ "$hash" == *[^0-9a-f]* ]]; then
      die "failed to parse sha256 from shasum output: ${out:q}"
    fi
    print -r -- "$hash"
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    local out hash
    out="$(print -rn -- "$s" | openssl dgst -sha256 2>/dev/null)"
    out="${out%%$'\n'*}"

    # Typical output: `SHA256(stdin)= <hash>` (last token is the hash).
    hash="${out##* }"
    hash="${hash//$'\r'/}"
    hash="${hash:l}"
    if (( ${#hash} != 64 )) || [[ "$hash" == *[^0-9a-f]* ]]; then
      die "failed to parse sha256 from openssl output: ${out:q}"
    fi
    print -r -- "$hash"
    return 0
  fi

  die "need shasum or openssl to compute manifest ids"
}

manifest_path_for_print_folder() {
  emulate -L zsh
  local print_folder="$1"
  validate_print_folder_name "$print_folder"
  local id
  id="$(sha256_hex "$print_folder")"
  print -r -- "$MANIFEST_DIR/${id}.tsv"
}

manifest_get_value() {
  emulate -L zsh
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1

  local k v
  while IFS=$'\t' read -r k v; do
    [[ "$k" == "$key" ]] || continue
    print -r -- "$v"
    return 0
  done < "$file"
  return 1
}

manifest_write() {
  emulate -L zsh
  local file="$1"
  local print_folder="$2"
  local derived_date="$3"
  local output_filename="$4"
  local processed="$5"

  local tmp="${file}.tmp.$$"
  {
    print -r -- $'remote_folder\t'"$print_folder"
    print -r -- $'derived_date\t'"$derived_date"
    print -r -- $'output_filename\t'"$output_filename"
    print -r -- $'processed\t'"$processed"
    print -r -- $'updated_at_utc\t'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >| "$tmp"
  mv -f -- "$tmp" "$file"
}

ffprobe_valid_mp4() {
  emulate -L zsh
  local mp4="$1"
  [[ -f "$mp4" ]] || return 1
  command -v ffprobe >/dev/null 2>&1 || return 1
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- "$mp4" >/dev/null 2>&1
}

remote_print_folder_date_yyyymmdd() {
  # Derive YYYY-MM-DD for the remote print folder.
  #
  # Rule: try birthtime first (GNU `ls --time=birth`), then fall back to mtime.
  # BusyBox ls does not support birthtime; we detect this via `ls` failure.
  #
  # IMPORTANT: the remote folder name can contain spaces, so we MUST avoid
  # parsing the filename field from `ls -l` output. We run a remote `read`
  # loop that captures date/time/tz fields and ignores the rest.
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"
  local print_folder="$3"

  validate_print_folder_name "$print_folder"
  local remote_path="$remote_dir/$print_folder"
  remote_require_dir "$host" "$remote_path"

  local remote_path_arg
  remote_path_arg="$(sh_single_quote "$remote_path")"

  local remote_cmd
  remote_cmd="sh -eu -c 'd=\"\$1\"; { ls -ld --full-time --time=birth -- \"\$d\" 2>/dev/null || ls -ld --full-time -- \"\$d\"; } | while IFS=\" \" read -r perm links owner group size date time tz rest; do printf \"%s\\n\" \"\$date\"; done' _ ${remote_path_arg}"

  local out
  out="$(ssh_remote "$host" "$remote_cmd")"
  out="${out%%$'\n'*}"
  if [[ "$out" != [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]]; then
    die "failed to derive remote date (expected YYYY-MM-DD) for ${host}:${remote_path} (got: ${out:q})"
  fi
  print -r -- "$out"
}

output_filename_for_print_folder() {
  emulate -L zsh
  local derived_date="$1"
  local print_folder="$2"
  validate_print_folder_name "$print_folder"
  [[ "$derived_date" == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]] || die "invalid derived date: $derived_date"
  print -r -- "${derived_date}_${print_folder}.mp4"
}

manifest_upsert_for_print_folder() {
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"
  local print_folder="$3"

  (( DRY_RUN )) && { log "dry-run: skip manifest update for $print_folder"; return 0; }

  validate_print_folder_name "$print_folder"
  local derived_date
  derived_date="$(remote_print_folder_date_yyyymmdd "$host" "$remote_dir" "$print_folder")"

  local output_filename
  output_filename="$(output_filename_for_print_folder "$derived_date" "$print_folder")"
  local output_path="$OUTPUT_DIR/$output_filename"

  local output_valid=0
  if ffprobe_valid_mp4 "$output_path"; then
    output_valid=1
  fi

  local processed=0
  (( output_valid )) && processed=1

  local manifest_path
  manifest_path="$(manifest_path_for_print_folder "$print_folder")"

  local existing_date=""
  local existing_out=""
  local existing_processed=""
  [[ -f "$manifest_path" ]] && existing_date="$(manifest_get_value "$manifest_path" derived_date || true)"
  [[ -f "$manifest_path" ]] && existing_out="$(manifest_get_value "$manifest_path" output_filename || true)"
  [[ -f "$manifest_path" ]] && existing_processed="$(manifest_get_value "$manifest_path" processed || true)"

  if [[ ! -f "$manifest_path" || "$existing_date" != "$derived_date" || "$existing_out" != "$output_filename" || "$existing_processed" != "$processed" ]]; then
    manifest_write "$manifest_path" "$print_folder" "$derived_date" "$output_filename" "$processed"
    log "manifest: upsert $manifest_path (processed=$processed)"
  else
    log "manifest: up-to-date for $print_folder"
  fi
}

manifest_folder_is_processed() {
  # Lookup: return success if manifest says processed=1 AND output validates.
  emulate -L zsh
  local print_folder="$1"
  validate_print_folder_name "$print_folder"

  local manifest_path
  manifest_path="$(manifest_path_for_print_folder "$print_folder")"
  [[ -f "$manifest_path" ]] || return 1

  local processed
  processed="$(manifest_get_value "$manifest_path" processed || true)"
  [[ "$processed" == "1" ]] || return 1

  local output_filename
  output_filename="$(manifest_get_value "$manifest_path" output_filename || true)"
  [[ -n "$output_filename" ]] || return 1
  ffprobe_valid_mp4 "$OUTPUT_DIR/$output_filename"
}

sync_one_print_dir_rsync() {
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"
  local print_folder="$3"

  validate_print_folder_name "$print_folder"

  local dest_dir="$INCOMING_DIR/$print_folder"
  maybe_mkdir_p "$dest_dir"

  local remote_path="$remote_dir/$print_folder/"
  local remote_path_q
  remote_path_q="$(sh_single_quote "$remote_path")"
  local src_spec="$host:$remote_path_q"

  # Compatibility-first flags: openrsync/protocol 29 (rsync 2.6.9 compatible).
  # Avoid newer flags like --protect-args/--partial-dir/--delay-updates.
  local -a rsync_cmd
  rsync_cmd=(rsync -rlt --no-owner --no-group --partial -- "$src_spec" "$dest_dir/")
  if (( VERBOSE )); then
    rsync_cmd=("${rsync_cmd[@]:0:1}" -v --stats "${rsync_cmd[@]:1}")
  fi
  run_cmd "${rsync_cmd[@]}"
}

sync_one_print_dir_tar() {
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"
  local print_folder="$3"

  validate_print_folder_name "$print_folder"

  local dest_dir="$INCOMING_DIR/$print_folder"
  if [[ -d "$dest_dir" ]] && (( FORCE == 0 )); then
    log "skip (local exists): $dest_dir"
    return 0
  fi

  maybe_mkdir_p "$INCOMING_DIR"

  local remote_dir_q="${remote_dir:q}"
  local print_folder_q="${print_folder:q}"
  local remote_cmd
  remote_cmd="sh -eu -c 'cd -- \"\$1\"; tar -cf - -- \"\$2\"' _ ${remote_dir_q} ${print_folder_q}"

  if (( DRY_RUN )); then
    print -rn -- "$PROG: dry-run: "
    print_argv_quoted ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$remote_cmd"
    print -rn -- " | "
    print_argv_quoted tar -xf - -C "$INCOMING_DIR"
    print -r -- ""
    return 0
  fi

  log "exec: tar stream ${host}:${remote_dir}/${print_folder} -> ${INCOMING_DIR}/"
  ssh_remote "$host" "$remote_cmd" | tar -xf - -C "$INCOMING_DIR"
}

sync_one_print_dir_scp() {
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"
  local print_folder="$3"

  validate_print_folder_name "$print_folder"

  local dest_dir="$INCOMING_DIR/$print_folder"
  if [[ -d "$dest_dir" ]] && (( FORCE == 0 )); then
    log "skip (local exists): $dest_dir"
    return 0
  fi

  maybe_mkdir_p "$INCOMING_DIR"

  local remote_path="$remote_dir/$print_folder"
  local remote_path_q
  remote_path_q="$(sh_single_quote "$remote_path")"
  local src_spec="$host:$remote_path_q"

  local -a scp_cmd
  scp_cmd=(scp -p -r "$src_spec" "$INCOMING_DIR/")
  run_cmd "${scp_cmd[@]}"
}

sync_remote_to_local() {
  emulate -L zsh
  local host="$1"
  local remote_dir="$2"
  local only_folder="$3"

  local transport
  transport="$(pick_transport "$host" "$remote_dir")"
  if (( VERBOSE )); then
    local transport_note=""
    (( DRY_RUN )) && transport_note=" (dry-run: remote probe skipped)"
    print -ru2 -- "$PROG: transport=$transport${transport_note}"
  fi

  local -a prints
  if [[ -n "$only_folder" ]]; then
    prints=("$only_folder")
  elif (( DRY_RUN )); then
    print -r -- "$PROG: dry-run: would list remote per-print directories from ${host}:${remote_dir}"
    case "$transport" in
      rsync)
        print -r -- "$PROG: dry-run: example: rsync -rlt --no-owner --no-group --partial -- \"${host}:${remote_dir}/<print-folder>/\" \"${INCOMING_DIR}/<print-folder>/\""
        ;;
      tar)
        local remote_cmd_example
        remote_cmd_example="sh -eu -c 'cd -- \"\$1\"; tar -cf - -- \"\$2\"' _ ${remote_dir:q} <print-folder>"
        print -r -- "$PROG: dry-run: example: ssh -o BatchMode=yes -o ConnectTimeout=10 -- \"$host\" \"$remote_cmd_example\" | tar -xf - -C \"$INCOMING_DIR\""
        ;;
      scp)
        print -r -- "$PROG: dry-run: example: scp -p -r \"${host}:${remote_dir}/<print-folder>\" \"${INCOMING_DIR}/\""
        ;;
    esac
    print -r -- "$PROG: dry-run: tip: pass --print <remote-folder> to show an exact per-folder sync command"
    return 0
  else
    prints=("${(@f)$(remote_list_print_dirs "$host" "$remote_dir")}")
  fi

  (( ${#prints[@]} > 0 )) || { log "no remote print directories found"; return 0; }

  local p
  for p in "${prints[@]}"; do
    validate_print_folder_name "$p"
    if manifest_folder_is_processed "$p"; then
      print -ru2 -- "$PROG: SKIP already-rendered: $p"
      continue
    fi
    log "sync: $p"
    case "$transport" in
      rsync)
        sync_one_print_dir_rsync "$host" "$remote_dir" "$p"
        ;;
      tar)
        sync_one_print_dir_tar "$host" "$remote_dir" "$p"
        ;;
      scp)
        sync_one_print_dir_scp "$host" "$remote_dir" "$p"
        ;;
      *)
        die "internal: unknown transport: $transport"
        ;;
    esac
  done
}

pick_ffmpeg() {
  # Keep existing behavior from the legacy script: prefer brew/system ffmpeg.
  if command -v ffmpeg >/dev/null 2>&1; then
    print -r -- "ffmpeg"
  elif [[ -x /opt/homebrew/bin/ffmpeg ]]; then
    print -r -- "/opt/homebrew/bin/ffmpeg"
  elif [[ -x /usr/local/bin/ffmpeg ]]; then
    print -r -- "/usr/local/bin/ffmpeg"
  else
    return 1
  fi
}

local_dir_mtime_date_yyyymmdd() {
  # Derive YYYY-MM-DD from local directory mtime.
  emulate -L zsh
  local dir="$1"
  [[ -d "$dir" ]] || die "not a directory: $dir"

  local epoch
  if ! epoch="$(stat -f %m -- "$dir" 2>/dev/null)"; then
    die "failed to stat mtime for: $dir"
  fi
  [[ "$epoch" == <-> ]] || die "failed to parse mtime epoch for: $dir (got: ${epoch:q})"

  local out
  out="$(date -r "$epoch" +%Y-%m-%d 2>/dev/null)" || die "failed to format mtime date for: $dir"
  [[ "$out" == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]] || die "invalid local derived date for: $dir (got: ${out:q})"
  print -r -- "$out"
}

enumerate_tlp_layer_frames_numeric() {
  # Populate $reply with absolute paths in numeric order by tlp_layer_<n>.
  # Non-numeric suffixes are ignored.
  emulate -L zsh
  setopt NULL_GLOB

  local dir="$1"
  [[ -d "$dir" ]] || die "not a directory: $dir"

  typeset -A by_n
  typeset -a ns
  local f base n
  for f in "$dir"/tlp_layer_*; do
    [[ -f "$f" ]] || continue
    base="${f:t}"
    n="${base##*_}"
    [[ "$n" == <-> ]] || continue
    if [[ -z "${by_n[$n]-}" ]]; then
      ns+="$n"
    fi
    by_n[$n]="${f:A}"
  done

  ns=(${(on)ns})
  reply=()
  for n in "${ns[@]}"; do
    reply+=("${by_n[$n]}")
  done
}

render_frame_dir_to_mp4() {
  emulate -L zsh
  local frames_dir="$1"
  local output_path="$2"

  [[ -d "$frames_dir" ]] || die "frames dir not found: $frames_dir"
  [[ -n "$output_path" ]] || die "internal: output path empty"

  local ffmpeg_bin
  ffmpeg_bin="$(pick_ffmpeg)" || die "ffmpeg not found"

  if [[ -f "$output_path" ]] && ffprobe_valid_mp4 "$output_path"; then
    log "render: skip (valid output exists): $output_path"
    return 0
  fi

  enumerate_tlp_layer_frames_numeric "$frames_dir"
  local -a frames
  frames=("${reply[@]}")
  if (( ${#frames[@]} == 0 )); then
    log "render: skip (no tlp_layer_<n> frames): $frames_dir"
    return 0
  fi

  maybe_mkdir_p "$WORK_DIR"
  maybe_mkdir_p "$OUTPUT_DIR"

  if (( DRY_RUN )); then
    print -r -- "$PROG: dry-run: would render ${#frames[@]} frames from $frames_dir"
    print -r -- "$PROG: dry-run: would write output to $output_path (atomic temp then mv)"
    return 0
  fi

  # Run the actual render in a subshell so trap cleanup is scoped.
  (
    emulate -L zsh
    set -euo pipefail
    setopt PIPE_FAIL
    setopt NULL_GLOB
    IFS=$'\n\t'

    local workdir
    workdir="$(mktemp -d "${WORK_DIR}/render.XXXXXXXX")" || die "failed to create work dir under $WORK_DIR"

    local out_base tmp_stub tmp_out
    out_base="${output_path:t}"
    tmp_stub="$(mktemp "${OUTPUT_DIR}/.${out_base}.tmp.XXXXXX")" || die "failed to create temp output under $OUTPUT_DIR"
    tmp_out="${tmp_stub}.mp4"
    mv -f -- "$tmp_stub" "$tmp_out"

    local keep_tmp=1
    cleanup_render() {
      rm -rf -- "$workdir" >/dev/null 2>&1 || true
      if (( keep_tmp )); then
        rm -f -- "$tmp_out" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_render EXIT INT TERM

    local i=1
    local src dst
    for src in "${frames[@]}"; do
      dst="$workdir/$(printf '%06d.jpg' "$i")"
      run_cmd ln -s -- "$src" "$dst"
      (( i++ ))
    done

    # Read the symlinked %06d.jpg sequence.
    # Keep flags conservative and compatible.
    run_cmd "$ffmpeg_bin" -hide_banner -y \
      -framerate "$FRAMERATE" \
      -i "$workdir/%06d.jpg" \
      -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
      "$tmp_out"

    ffprobe_valid_mp4 "$tmp_out" || die "render produced invalid mp4 (ffprobe failed): $tmp_out"

    mv -f -- "$tmp_out" "$output_path"
    ffprobe_valid_mp4 "$output_path" || die "render output failed ffprobe after move: $output_path"

    keep_tmp=0
  )
  return 0
}

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
cd "$SCRIPT_DIR" || die "failed to cd to script dir: $SCRIPT_DIR"

BASE_DIR="./ecc"
INCOMING_DIR="$BASE_DIR/incoming"
OUTPUT_DIR="$BASE_DIR/output"
STATE_DIR="$BASE_DIR/state"
MANIFEST_DIR="$STATE_DIR/manifest"
LOGS_DIR="$BASE_DIR/logs"
WORK_DIR="$BASE_DIR/work"

ECC_HOST="${ECC_HOST:-elegoo}"
ECC_REMOTE_DIR="${ECC_REMOTE_DIR:-/user-resource/aic_tlp}"
FRAMERATE="${FRAMERATE:-30}"

DRY_RUN=0
FORCE=0
VERBOSE=0
KEEP_FRAMES=0

DO_LIST_REMOTE=0
DO_PRINT=0
DO_PRINT_ONE=0
PRINT_REMOTE_FOLDER=""

RENDER_INPUT_DIR=""

MODE=""

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --keep-frames)
      KEEP_FRAMES=1
      ;;
    --force)
      FORCE=1
      ;;
    --verbose)
      VERBOSE=1
      ;;
    --list-remote)
      DO_LIST_REMOTE=1
      ;;
    --print)
      shift || true
      (( $# > 0 )) || die "--print requires <remote-folder>"
      DO_PRINT=1
      PRINT_REMOTE_FOLDER="$1"
      ;;
    --print-one)
      DO_PRINT_ONE=1
      ;;
    --input)
      shift || true
      (( $# > 0 )) || die "--input requires <local-dir>"
      RENDER_INPUT_DIR="$1"
      ;;
    --sync-only)
      [[ -z "$MODE" ]] || die "only one mode flag allowed (got --sync-only after $MODE)"
      MODE="sync"
      ;;
    --render-only)
      [[ -z "$MODE" ]] || die "only one mode flag allowed (got --render-only after $MODE)"
      MODE="render"
      ;;
    --)
      shift
      break
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

if (( $# > 0 )); then
  die "unexpected positional arguments: $*"
fi

# Default behavior:
# - If no explicit mode is given, run the full pipeline (sync then render).
# - Exception: --input implies render-only (no remote sync needed).
if [[ -z "$MODE" && -n "$RENDER_INPUT_DIR" ]]; then
  MODE="render"
elif [[ -z "$MODE" ]] && (( DO_LIST_REMOTE == 0 && DO_PRINT == 0 && DO_PRINT_ONE == 0 )); then
  MODE="both"
fi

if (( DO_LIST_REMOTE )); then
  if (( DRY_RUN )); then
    if (( VERBOSE )); then
      print -ru2 -- "$PROG: dry-run: transport=$(pick_transport "$ECC_HOST" "$ECC_REMOTE_DIR") (no remote probe)"
    fi
    print -r -- "$PROG: dry-run: would list remote per-print directories from ${ECC_HOST}:${ECC_REMOTE_DIR}"
    exit 0
  fi

  if (( VERBOSE )); then
    print -ru2 -- "$PROG: transport=$(pick_transport "$ECC_HOST" "$ECC_REMOTE_DIR")"
  fi
  remote_list_print_dirs "$ECC_HOST" "$ECC_REMOTE_DIR"
  exit 0
fi

if (( DRY_RUN == 0 )) && [[ "$MODE" == "sync" || "$MODE" == "render" || "$MODE" == "both" ]]; then
  acquire_state_lock_or_die
fi

if (( DO_PRINT )); then
  print -r -- "Resolved paths:"
  print -r -- "  script_dir: $SCRIPT_DIR"
  print -r -- "  base_dir:   $BASE_DIR"
  print -r -- "  incoming:   $INCOMING_DIR"
  print -r -- "  output:     $OUTPUT_DIR"
  print -r -- "  state:      $STATE_DIR"
  print -r -- "  manifest:   $MANIFEST_DIR"
  print -r -- "  logs:       $LOGS_DIR"
  print -r -- "  work:       $WORK_DIR"
  print -r -- "Remote target:"
  print -r -- "  ${ECC_HOST}:${ECC_REMOTE_DIR}/${PRINT_REMOTE_FOLDER}"

  validate_print_folder_name "$PRINT_REMOTE_FOLDER"

  if (( DRY_RUN )); then
    print -r -- "Derived output (dry-run: remote timestamp not queried):"
    print -r -- "  date:       <YYYY-MM-DD>"
    print -r -- "  mp4:        $OUTPUT_DIR/<YYYY-MM-DD>_${PRINT_REMOTE_FOLDER}.mp4"
    print -r -- "  manifest:   $(manifest_path_for_print_folder "$PRINT_REMOTE_FOLDER")"
  else
    typeset manifest_path
    manifest_path="$(manifest_path_for_print_folder "$PRINT_REMOTE_FOLDER")"

    typeset -i already_processed=0
    if manifest_folder_is_processed "$PRINT_REMOTE_FOLDER"; then
      already_processed=1
    fi

    typeset derived_date=""
    typeset output_filename=""
    typeset output_path=""
    if (( already_processed )); then
      derived_date="$(manifest_get_value "$manifest_path" derived_date || true)"
      output_filename="$(manifest_get_value "$manifest_path" output_filename || true)"
      [[ -n "$derived_date" && -n "$output_filename" ]] || die "manifest inconsistent for processed folder: $PRINT_REMOTE_FOLDER ($manifest_path)"
      output_path="$OUTPUT_DIR/$output_filename"
      print -r -- "Derived output (from manifest; already processed):"
    else
      derived_date="$(remote_print_folder_date_yyyymmdd "$ECC_HOST" "$ECC_REMOTE_DIR" "$PRINT_REMOTE_FOLDER")"
      output_filename="$(output_filename_for_print_folder "$derived_date" "$PRINT_REMOTE_FOLDER")"
      output_path="$OUTPUT_DIR/$output_filename"
      print -r -- "Derived output:"
    fi

    print -r -- "  date:       $derived_date"
    print -r -- "  mp4:        $output_path"
    if [[ -f "$output_path" ]] && ffprobe_valid_mp4 "$output_path"; then
      print -r -- "  mp4_valid:  yes"
    elif [[ -f "$output_path" ]]; then
      print -r -- "  mp4_valid:  no (ffprobe failed)"
    else
      print -r -- "  mp4_valid:  no (missing)"
    fi
    print -r -- "  manifest:   $manifest_path"
    if (( already_processed )); then
      print -r -- "  processed:  yes"
    else
      print -r -- "  processed:  no"
    fi
  fi
fi

if (( DO_PRINT_ONE )) && [[ -z "$MODE" ]]; then
  (( DO_PRINT == 0 )) || die "only one of --print or --print-one allowed"
  if (( DRY_RUN )); then
    die "--print-one is not available in --dry-run (requires remote listing)"
  fi
  typeset -a prints
  prints=(${(@f)$(remote_list_print_dirs "$ECC_HOST" "$ECC_REMOTE_DIR")})
  (( ${#prints[@]} > 0 )) || die "no remote print directories found under ${ECC_HOST}:${ECC_REMOTE_DIR}"
  DO_PRINT=1
  PRINT_REMOTE_FOLDER="${prints[1]}"
  # Re-run the print block by falling through to the MODE dispatch.
  print -r -- "Selected remote folder (first): $PRINT_REMOTE_FOLDER"
  print -r -- ""
  print -r -- "Resolved paths:"
  print -r -- "  script_dir: $SCRIPT_DIR"
  print -r -- "  base_dir:   $BASE_DIR"
  print -r -- "  incoming:   $INCOMING_DIR"
  print -r -- "  output:     $OUTPUT_DIR"
  print -r -- "  state:      $STATE_DIR"
  print -r -- "  manifest:   $MANIFEST_DIR"
  print -r -- "  logs:       $LOGS_DIR"
  print -r -- "  work:       $WORK_DIR"
  print -r -- "Remote target:"
  print -r -- "  ${ECC_HOST}:${ECC_REMOTE_DIR}/${PRINT_REMOTE_FOLDER}"
  typeset derived_date
  derived_date="$(remote_print_folder_date_yyyymmdd "$ECC_HOST" "$ECC_REMOTE_DIR" "$PRINT_REMOTE_FOLDER")"
  typeset output_filename
  output_filename="$(output_filename_for_print_folder "$derived_date" "$PRINT_REMOTE_FOLDER")"
  typeset output_path="$OUTPUT_DIR/$output_filename"
  typeset manifest_path
  manifest_path="$(manifest_path_for_print_folder "$PRINT_REMOTE_FOLDER")"
  print -r -- "Derived output:"
  print -r -- "  date:       $derived_date"
  print -r -- "  mp4:        $output_path"
  print -r -- "  manifest:   $manifest_path"
  exit 0
fi

dispatch_sync() {
  emulate -L zsh
  setopt NULL_GLOB
  typeset only_print=""
  (( DO_PRINT )) && only_print="$PRINT_REMOTE_FOLDER"

  if [[ -n "$only_print" ]] && manifest_folder_is_processed "$only_print"; then
    print -ru2 -- "$PROG: SKIP already-rendered: $only_print"
    return 0
  fi

  sync_remote_to_local "$ECC_HOST" "$ECC_REMOTE_DIR" "$only_print"
  if [[ -n "$only_print" ]]; then
    manifest_upsert_for_print_folder "$ECC_HOST" "$ECC_REMOTE_DIR" "$only_print"
  elif (( DRY_RUN == 0 )); then
    # Best-effort manifest bootstrap for any locally-synced folders.
    typeset d
    for d in "$INCOMING_DIR"/*; do
      [[ -d "$d" ]] || continue
      manifest_upsert_for_print_folder "$ECC_HOST" "$ECC_REMOTE_DIR" "${d:t}"
    done
  fi
  return 0
}

dispatch_render() {
  emulate -L zsh
  setopt NULL_GLOB

  [[ -z "$RENDER_INPUT_DIR" || -d "$RENDER_INPUT_DIR" ]] || die "--input is not a directory: $RENDER_INPUT_DIR"
  if [[ -n "$RENDER_INPUT_DIR" ]] && (( DO_PRINT || DO_PRINT_ONE )); then
    die "--input cannot be combined with --print/--print-one (it renders exactly one local directory)"
  fi

  if (( DO_PRINT_ONE )); then
    # In render mode, --print-one means: pick one local incoming folder.
    typeset -a locals
    locals=()
    typeset d
    for d in "$INCOMING_DIR"/*; do
      [[ -d "$d" ]] || continue
      locals+=("${d:t}")
    done
    (( ${#locals[@]} > 0 )) || die "no local print directories found under $INCOMING_DIR"
    # Deterministic pick: lexicographically first name.
    locals=(${(o)locals})
    DO_PRINT=1
    PRINT_REMOTE_FOLDER="${locals[1]}"
    log "render: selected local folder (first): $PRINT_REMOTE_FOLDER"
  fi

  if [[ -n "$RENDER_INPUT_DIR" ]]; then
    typeset local_folder="${RENDER_INPUT_DIR:A}"
    typeset print_folder="${local_folder:t}"
    validate_print_folder_name "$print_folder"
    typeset derived_date
    derived_date="$(local_dir_mtime_date_yyyymmdd "$local_folder")"
    typeset output_filename
    output_filename="$(output_filename_for_print_folder "$derived_date" "$print_folder")"
    typeset output_path="$OUTPUT_DIR/$output_filename"
    log "render: input=$local_folder output=$output_path"
    render_frame_dir_to_mp4 "$local_folder" "$output_path"
    return 0
  fi

  typeset -a prints
  prints=()
  typeset pd
  if (( DO_PRINT )); then
    validate_print_folder_name "$PRINT_REMOTE_FOLDER"
    prints=("$PRINT_REMOTE_FOLDER")
  else
    for pd in "$INCOMING_DIR"/*; do
      [[ -d "$pd" ]] || continue
      prints+=("${pd:t}")
    done
  fi

  (( ${#prints[@]} > 0 )) || { log "render: no local print directories found under $INCOMING_DIR"; return 0; }

  typeset p
  for p in "${prints[@]}"; do
    validate_print_folder_name "$p"
    typeset frames_dir="$INCOMING_DIR/$p"

    if manifest_folder_is_processed "$p"; then
      print -ru2 -- "$PROG: SKIP already-rendered: $p"
      if (( KEEP_FRAMES == 0 )) && [[ -d "$frames_dir" ]]; then
        safe_prune_incoming_dir "$frames_dir"
      fi
      continue
    fi

    [[ -d "$frames_dir" ]] || { log "render: skip (missing local dir): $frames_dir"; continue; }

    typeset derived_date
    if (( DRY_RUN )); then
      # No remote probes in dry-run; use local mtime for a valid placeholder.
      derived_date="$(local_dir_mtime_date_yyyymmdd "$frames_dir")"
    else
      derived_date="$(remote_print_folder_date_yyyymmdd "$ECC_HOST" "$ECC_REMOTE_DIR" "$p")"
    fi
    typeset output_filename
    output_filename="$(output_filename_for_print_folder "$derived_date" "$p")"
    typeset output_path="$OUTPUT_DIR/$output_filename"

    log "render: $p -> $output_path"
    render_frame_dir_to_mp4 "$frames_dir" "$output_path"

    if (( DRY_RUN )); then
      (( KEEP_FRAMES )) && continue
      typeset -i would_prune=0
      if ffprobe_valid_mp4 "$output_path"; then
        would_prune=1
      else
        enumerate_tlp_layer_frames_numeric "$frames_dir"
        (( ${#reply[@]} > 0 )) && would_prune=1
      fi
      (( would_prune )) && safe_prune_incoming_dir "$frames_dir"
      continue
    fi

    if ffprobe_valid_mp4 "$output_path"; then
      manifest_upsert_for_print_folder "$ECC_HOST" "$ECC_REMOTE_DIR" "$p"
      if (( KEEP_FRAMES == 0 )); then
        safe_prune_incoming_dir "$frames_dir"
      fi
    else
      log "render: skip prune/manifest (output not valid): $output_path"
    fi
  done
  return 0
}

case "$MODE" in
  "")
    if (( DO_LIST_REMOTE == 0 && DO_PRINT == 0 )); then
      if (( DRY_RUN && VERBOSE )); then
        print -ru2 -- "$PROG: dry-run: transport=$(pick_transport "$ECC_HOST" "$ECC_REMOTE_DIR") (no remote probe)"
      fi
      usage
    fi
    exit 0
    ;;
  sync)
    ensure_local_layout
    dispatch_sync
    exit 0
    ;;
  render)
    ensure_local_layout
    dispatch_render
    exit 0
    ;;
  both)
    ensure_local_layout
    dispatch_sync
    dispatch_render
    exit 0
    ;;
  *)
    die "internal: unknown mode: $MODE"
    ;;
esac
