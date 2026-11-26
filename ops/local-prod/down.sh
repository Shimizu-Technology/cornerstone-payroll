#!/usr/bin/env bash
# Stop everything the local production copy runs: one command.
#
#   ops/local-prod/down.sh           # stop; keep the data for the next up.sh
#   ops/local-prod/down.sh --purge   # stop and delete the data directory too
#
# Stops only the mirror's own processes, by the pid files it wrote.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

purge=false
[[ "${1:-}" == "--purge" ]] && purge=true

release() {
  if [[ -n "${DEV_LIFECYCLE_SESSION:-}" ]] && command -v dev-lifecycle >/dev/null 2>&1; then
    dev-lifecycle release --session "$DEV_LIFECYCLE_SESSION" process "$1" >/dev/null 2>&1 || true
  fi
}

stop_pid() {
  local name="$1" file="$RUN/$1.pid"
  pid_alive "$file" || { rm -f "$file"; return 0; }
  local pid; pid="$(cat "$file")"
  log "stopping $name ($pid)"
  kill "$pid" 2>/dev/null || true
  for _ in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$file"
  release "$pid"
}

[[ -d "$STATE" ]] || { log "nothing to stop ($STATE does not exist)"; exit 0; }

stop_pid staff
stop_pid worker
stop_pid employee
if pid_alive "$RUN/caddy.pid"; then
  pid="$(cat "$RUN/caddy.pid")"
  log "stopping caddy ($pid)"
  clean_env caddy stop --address "$CADDY_ADMIN" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
  rm -f "$RUN/caddy.pid"
  release "$pid"
fi
stop_pid redis
if [[ -f "$STATE/pg/data/postmaster.pid" ]]; then
  pid="$(head -1 "$STATE/pg/data/postmaster.pid")"
  log "stopping postgres ($pid)"
  clean_env "$PG_BIN/pg_ctl" -D "$STATE/pg/data" -m fast -w stop >/dev/null 2>&1 || true
  release "$pid"
fi

if $purge; then
  log "deleting $STATE"
  rm -rf "$STATE"
fi
log "down."
