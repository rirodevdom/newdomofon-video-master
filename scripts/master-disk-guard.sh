#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${NEWDOMOFON_ENV_FILE:-/etc/newdomofon-video/app.env}"
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

STATE_DIR="${MASTER_DISK_GUARD_STATE_DIR:-/run/newdomofon-video}"
STATE_FILE="$STATE_DIR/master-disk-state.json"
CRITICAL_MARKER="${MASTER_DISK_CRITICAL_MARKER:-$STATE_DIR/master-disk-critical}"
LOCK_FILE="${MASTER_DISK_GUARD_LOCK_FILE:-/run/lock/newdomofon-video-master-disk-guard.lock}"
PATHS_RAW="${MASTER_DISK_GUARD_PATHS:-/:/var/lib/postgresql:/var/log/newdomofon-video}"
MIN_FREE_BYTES="${MASTER_DISK_MIN_FREE_BYTES:-2147483648}"
MIN_FREE_PERCENT="${MASTER_DISK_MIN_FREE_PERCENT:-5}"
RESUME_FREE_BYTES="${MASTER_DISK_RESUME_FREE_BYTES:-4294967296}"
RESUME_FREE_PERCENT="${MASTER_DISK_RESUME_FREE_PERCENT:-10}"
MIN_FREE_INODES_PERCENT="${MASTER_DISK_MIN_FREE_INODES_PERCENT:-5}"
RESUME_FREE_INODES_PERCENT="${MASTER_DISK_RESUME_FREE_INODES_PERCENT:-8}"
JOURNAL_MAX_SIZE="${MASTER_JOURNAL_MAX_SIZE:-512M}"
JOURNAL_MAX_AGE="${MASTER_JOURNAL_MAX_AGE:-7d}"
STALE_TMP_MINUTES="${MASTER_DISK_STALE_TMP_MINUTES:-60}"
APT_CLEAN="${MASTER_DISK_APT_CLEAN_ON_CRITICAL:-true}"

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then exit 0; fi

log() {
  local level="$1"; shift
  logger -t newdomofon-master-disk-guard -p "daemon.${level}" -- "$*" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date -Is)" "$level" "$*"
}

is_true() {
  case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
for value in "$MIN_FREE_BYTES" "$MIN_FREE_PERCENT" "$RESUME_FREE_BYTES" "$RESUME_FREE_PERCENT" \
             "$MIN_FREE_INODES_PERCENT" "$RESUME_FREE_INODES_PERCENT" "$STALE_TMP_MINUTES"; do
  if ! is_uint "$value"; then
    log err "invalid numeric disk guard configuration: $value"
    exit 0
  fi
done

fs_stats() {
  local target="$1" bytes_line inode_line total available used_pct inode_used_pct inode_free_pct
  bytes_line="$(df -P -B1 "$target" 2>/dev/null | awk 'NR==2 {print $2, $4, $5}')" || return 1
  inode_line="$(df -Pi "$target" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')" || return 1
  read -r total available used_pct <<<"$bytes_line"
  used_pct="${used_pct%%%}"
  inode_used_pct="$inode_line"
  if ! [[ "$inode_used_pct" =~ ^[0-9]+$ ]]; then inode_used_pct=0; fi
  inode_free_pct=$((100 - inode_used_pct))
  printf '%s %s %s %s\n' "$total" "$available" "$used_pct" "$inode_free_pct"
}

required_bytes() {
  local total="$1" absolute="$2" percent="$3" by_percent
  by_percent=$((total * percent / 100))
  if (( absolute > by_percent )); then printf '%s\n' "$absolute"; else printf '%s\n' "$by_percent"; fi
}

cleanup_safe_space() {
  journalctl --vacuum-size="$JOURNAL_MAX_SIZE" --vacuum-time="$JOURNAL_MAX_AGE" >/dev/null 2>&1 || true
  find /tmp /var/tmp -xdev -type d \
    \( -name 'newdomofon-*' -o -name 'nd-export-*' -o -name 'npm-*' \) \
    -mmin "+$STALE_TMP_MINUTES" -print0 2>/dev/null \
    | xargs -0r rm -rf -- 2>/dev/null || true
}

write_state() {
  local state="$1" reason="$2" worst_path="$3" total="$4" available="$5" used_pct="$6" inode_free_pct="$7" required_start="$8" required_resume="$9"
  local tmp="$STATE_FILE.tmp.$$"
  cat >"$tmp" <<JSON
{"ok":$([[ "$state" == "ok" ]] && echo true || echo false),"state":"$state","reason":"$reason","worst_path":"$worst_path","total_bytes":$total,"available_bytes":$available,"used_percent":$used_pct,"inode_free_percent":$inode_free_pct,"required_start_bytes":$required_start,"required_resume_bytes":$required_resume,"checked_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
  mv -f "$tmp" "$STATE_FILE"
}

scan_paths() {
  local mode="$1" path total available used_pct inode_free_pct required candidate_score
  local worst_score=-1 worst_path='' worst_total=0 worst_available=0 worst_used=0 worst_inode=100 worst_required=0
  IFS=':' read -r -a paths <<<"$PATHS_RAW"
  for path in "${paths[@]}"; do
    [[ -n "$path" && -e "$path" ]] || continue
    read -r total available used_pct inode_free_pct < <(fs_stats "$path") || continue
    if [[ "$mode" == start ]]; then
      required="$(required_bytes "$total" "$MIN_FREE_BYTES" "$MIN_FREE_PERCENT")"
    else
      required="$(required_bytes "$total" "$RESUME_FREE_BYTES" "$RESUME_FREE_PERCENT")"
    fi
    candidate_score=0
    if (( available < required )); then candidate_score=$((candidate_score + 1000000 + (required - available) / 1048576)); fi
    if [[ "$mode" == start ]] && (( inode_free_pct < MIN_FREE_INODES_PERCENT )); then candidate_score=$((candidate_score + 2000000 + MIN_FREE_INODES_PERCENT - inode_free_pct)); fi
    if [[ "$mode" == resume ]] && (( inode_free_pct < RESUME_FREE_INODES_PERCENT )); then candidate_score=$((candidate_score + 2000000 + RESUME_FREE_INODES_PERCENT - inode_free_pct)); fi
    if (( candidate_score > worst_score )); then
      worst_score=$candidate_score; worst_path="$path"; worst_total=$total; worst_available=$available; worst_used=$used_pct; worst_inode=$inode_free_pct; worst_required=$required
    fi
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$worst_score" "$worst_path" "$worst_total" "$worst_available" "$worst_used" "$worst_inode" "$worst_required"
}

cleanup_safe_space
read -r score worst_path total available used_pct inode_free_pct required_start < <(scan_paths start | tr '\t' ' ')
required_resume="$(required_bytes "$total" "$RESUME_FREE_BYTES" "$RESUME_FREE_PERCENT")"

if (( score >= 1000000 )); then
  if is_true "$APT_CLEAN"; then apt-get clean >/dev/null 2>&1 || true; fi
  cleanup_safe_space
  read -r score worst_path total available used_pct inode_free_pct required_start < <(scan_paths start | tr '\t' ' ')
  required_resume="$(required_bytes "$total" "$RESUME_FREE_BYTES" "$RESUME_FREE_PERCENT")"
fi

if (( score >= 1000000 )); then
  reason="filesystem_low_space"
  if (( inode_free_pct < MIN_FREE_INODES_PERCENT )); then reason="filesystem_low_inodes"; fi
  write_state critical "$reason" "$worst_path" "$total" "$available" "$used_pct" "$inode_free_pct" "$required_start" "$required_resume"
  cp -f "$STATE_FILE" "$CRITICAL_MARKER"
  log crit "master entered disk critical mode path=$worst_path available=$available required=$required_start inode_free=${inode_free_pct}%"
  exit 0
fi

read -r resume_score resume_path resume_total resume_available resume_used resume_inode resume_required < <(scan_paths resume | tr '\t' ' ')
if (( resume_score < 1000000 )); then
  rm -f "$CRITICAL_MARKER"
  write_state ok healthy "$resume_path" "$resume_total" "$resume_available" "$resume_used" "$resume_inode" \
    "$(required_bytes "$resume_total" "$MIN_FREE_BYTES" "$MIN_FREE_PERCENT")" "$resume_required"
else
  write_state warning below_resume_watermark "$resume_path" "$resume_total" "$resume_available" "$resume_used" "$resume_inode" \
    "$(required_bytes "$resume_total" "$MIN_FREE_BYTES" "$MIN_FREE_PERCENT")" "$resume_required"
fi
exit 0
