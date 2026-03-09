#!/usr/bin/env bash
# =============================================================================
# MoSa Payroll Operator Entrypoint
# =============================================================================
# Usage:
#   scripts/mosa_run.sh                   # Full pipeline: import + validate
#   scripts/mosa_run.sh validate           # Validation only (dry-run safe)
#   scripts/mosa_run.sh import             # Import only, no validate
#   scripts/mosa_run.sh download           # Re-run Gmail attachment download
#   scripts/mosa_run.sh backfill           # Backfill missing employees only
#   scripts/mosa_run.sh help               # Show this help
#
# Requirements:
#   - Run from project root: ~/work/cornerstone-payroll/
#   - Rails app in ./api/  (bundle exec rails available)
#   - Python 3 with gog configured for Gmail download
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
API_DIR="$PROJECT_ROOT/api"
DATA_DIR="$PROJECT_ROOT/data/mosa-2025"

export PATH="$HOME/.rbenv/shims:$PATH"

COMMAND="${1:-all}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── Pre-flight checks ──────────────────────────────────────────────────────────
check_deps() {
  [[ -d "$API_DIR" ]]       || die "API directory not found: $API_DIR"
  [[ -d "$DATA_DIR/raw" ]]  || die "Raw data directory not found: $DATA_DIR/raw"
  command -v ruby >/dev/null || die "ruby not found"
  (cd "$API_DIR" && bundle check >/dev/null 2>&1) || die "Bundle not installed. Run: cd api && bundle install"
}

# ── Commands ───────────────────────────────────────────────────────────────────
cmd_download() {
  log "=== Step 1/4: Download Gmail Attachments ==="
  command -v gog >/dev/null || die "gog not found. Install via: npm i -g @shimizu-technology/gog"
  python3 "$SCRIPT_DIR/download_mosa_attachments.py"
  log "Download complete."
}

cmd_backfill() {
  log "=== Step 2/4: Backfill Missing Employees ==="
  (cd "$API_DIR" && bundle exec rails runner scripts/mosa_backfill_employees.rb)
  log "Backfill complete."
}

cmd_import() {
  log "=== Step 3/4: Import Payroll ==="
  local apply_flag="${MOSA_APPLY:-0}"
  if [[ "$apply_flag" == "1" ]]; then
    log "WARNING: MOSA_APPLY=1 — will WRITE payroll items to database."
    read -r -p "Type 'yes' to confirm live import: " confirm
    [[ "$confirm" == "yes" ]] || die "Aborted by user."
    (cd "$API_DIR" && MOSA_APPLY=1 bundle exec rails runner scripts/mosa_full_year_validation.rb)
  else
    log "Dry-run mode (MOSA_APPLY=0). Running validation/import preview workflow."
    (cd "$API_DIR" && bundle exec rails runner scripts/mosa_full_year_validation.rb)
  fi
  log "Import step complete (MOSA_APPLY=${apply_flag})"
}

cmd_validate() {
  log "=== Step 4/4: Full Year Validation ==="
  (cd "$API_DIR" && bundle exec rails runner scripts/mosa_full_year_validation.rb)
  log "Validation complete. Report: $DATA_DIR/validation_report.md"
}

# ── Main ───────────────────────────────────────────────────────────────────────
check_deps

case "$COMMAND" in
  all)
    log "Running full MoSa pipeline (validate only — set MOSA_APPLY=1 for live import)"
    cmd_validate
    ;;
  download)
    cmd_download
    ;;
  backfill)
    cmd_backfill
    ;;
  import)
    cmd_import
    ;;
  validate)
    cmd_validate
    ;;
  help|--help|-h)
    head -20 "$0" | grep -E '^#' | sed 's/^# *//'
    ;;
  *)
    die "Unknown command: $COMMAND. Run: scripts/mosa_run.sh help"
    ;;
esac

log "Done."
