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

# Stops one service and removes its pid file only once the process is gone.
stop_service() {
  local name="$1" pid
  pid="$(service_pid "$name")"
  [[ -n "$pid" ]] || return 0
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
    for _ in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  fi
  kill -0 "$pid" 2>/dev/null && die "$name ($pid) is still running; stop it by hand and rerun down.sh"
  rm -f "$RUN/$name.pid"
  release "$pid"
}

# Anything still using the data directory or the mirror's ports, whatever its
# pid files say.
live_users() {
  local target="$1" spelling found="" raw="${LOCAL_PROD_HOME:-}"
  while [[ "$raw" == */ && "$raw" != / ]]; do raw="${raw%/}"; done
  # Every spelling of the path a command line might use (/private/tmp is /tmp).
  for spelling in "$target" "${target#/private}" ${raw:+"$raw"}; do
    found+="$(ps -axww -o pid=,command= | grep -F -- "$spelling/" | grep -v -F -- "grep -F" || true)"$'\n'
  done
  # Any process with a file or working directory inside it.
  found+="$(lsof -n +D "$target" -Fp 2>/dev/null | sed -n 's/^p//p' || true)"
  found="$(echo "$found" | awk 'NF {print $1}' | grep -vx -e "$$" -e "$PPID" | sort -u | tr '\n' ' ' || true)"
  [[ -z "${found// /}" ]] || printf 'processes: %s\n' "$found"
  local port holder
  for port in "$PG_PORT" "$CADDY_ADMIN_PORT" "$REDIS_PORT" "$HTTPS_PORT" "$STAFF_PORT" "$EMPLOYEE_PORT"; do
    holder="$(port_holder "$port")"
    [[ -z "$holder" ]] || printf 'port %s: pid %s\n' "$port" "$holder"
  done
}

purge_state() {
  [[ -e "$STATE" ]] || return 0
  check_state_path
  local target; target="$(real_dir "$STATE")"
  [[ -f "$target/$STATE_MARKER" && ! -L "$target/$STATE_MARKER" ]] ||
    die "refusing to delete $target: it has no $STATE_MARKER marker (not a local-prod data directory)"
  service_alive postgres && die "refusing to delete $target: postgres is still running"
  service_alive caddy && die "refusing to delete $target: caddy is still running"
  local users; users="$(live_users "$target")"
  [[ -z "$users" ]] || die "refusing to delete $target: still in use ($(echo "$users" | tr '\n' ';'))"
  log "deleting $target"
  rm -rf "$target"
}

[[ -d "$STATE" ]] || { log "nothing to stop ($STATE does not exist)"; exit 0; }
[[ ! -L "$STATE" ]] || die "refusing $STATE: it is a symlink"

stop_service staff
stop_service worker
stop_service employee
stop_service caddy
stop_service redis
if pid="$(service_pid postgres)" && [[ -n "$pid" ]]; then
  log "stopping postgres ($pid)"
  clean_env "$PG_BIN/pg_ctl" -D "$STATE/pg/data" -m fast -w stop >/dev/null 2>&1 || warn "pg_ctl stop failed (see $LOGS/postgres.log)"
  kill -0 "$pid" 2>/dev/null && die "postgres ($pid) is still running; check $LOGS/postgres.log"
  release "$pid"
fi

$purge && purge_state
log "down."
