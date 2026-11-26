#!/usr/bin/env bash
# Stop everything the local production copy runs: one command.
#
#   ops/local-prod/down.sh           # stop; keep the data for the next up.sh
#   ops/local-prod/down.sh --purge   # stop and delete the data directory too
#
# Signals only processes whose pid file and command line both match the
# service, so a stale pid file never stops anything else.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

purge=false
case "${1:-}" in
  "") ;;
  --purge) purge=true ;;
  *) die "unknown option ${1}; use --purge or nothing" ;;
esac
[[ $# -le 1 ]] || die "down.sh takes at most one option (--purge)"

stop_service() {
  local name="$1" pid
  pid="$(service_pid "$name")"
  [[ -n "$pid" ]] || { rm -f "$RUN/$name.pid"; return 0; }
  log "stopping $name ($pid)"
  if [[ "$name" == caddy ]]; then
    clean_env caddy stop --address "$CADDY_ADMIN" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
  else
    kill "$pid" 2>/dev/null || true
  fi
  for _ in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    warn "$name ($pid) ignored SIGTERM; sending SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$RUN/$name.pid"
  release "$pid"
}

purge_state() {
  local target home repo
  [[ -d "$STATE" ]] || return 0
  target="$(cd "$STATE" && pwd -P)"
  home="$(cd "$HOME" && pwd -P)"
  repo="$(cd "$REPO_DIR" && pwd -P)"
  case "$target" in
    / | "$home" | /tmp | /private/tmp | /var | /private/var) die "refusing to delete $target" ;;
  esac
  [[ "$repo" == "$target" || "$repo" == "$target"/* ]] && die "refusing to delete $target: it contains this repository"
  [[ -f "$target/$STATE_MARKER" ]] || die "refusing to delete $target: it has no $STATE_MARKER marker (not a local-prod data directory)"
  service_alive postgres && die "refusing to delete $target: postgres is still running"
  service_alive caddy && die "refusing to delete $target: caddy is still running"
  log "deleting $target"
  rm -rf "$target"
}

[[ -d "$STATE" ]] || { log "nothing to stop ($STATE does not exist)"; exit 0; }

stop_service staff
stop_service worker
stop_service employee
stop_service caddy
stop_service redis
if pid="$(service_pid postgres)" && [[ -n "$pid" ]]; then
  log "stopping postgres ($pid)"
  clean_env "$PG_BIN/pg_ctl" -D "$STATE/pg/data" -m fast -w stop >/dev/null 2>&1 || warn "pg_ctl stop failed (see $LOGS/postgres.log)"
  release "$pid"
fi

$purge && purge_state
log "down."
