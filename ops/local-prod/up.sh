#!/usr/bin/env bash
# Bring up the local production copy: one command, safe to rerun.
#
#   ops/local-prod/up.sh                 # RLS enforced (the default)
#   LOCAL_PROD_RLS_PHASE=shadow ops/local-prod/up.sh   # fresh data only
#
# See ops/local-prod/README.md for what runs and how to reach it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PHASE="${LOCAL_PROD_RLS_PHASE:-enforced}"
[[ "$PHASE" == enforced || "$PHASE" == shadow ]] || die "LOCAL_PROD_RLS_PHASE must be enforced or shadow"
[[ $# -eq 0 ]] || die "up.sh takes no arguments (see README.md)"

on_exit() {
  local status=$?
  ((status == 0)) && return
  printf '[local-prod] up.sh stopped early. Logs: %s. Fix the cause and rerun up.sh (it resumes), or run down.sh to stop what started.\n' "$LOGS" >&2
}
trap on_exit EXIT

ensure_secrets() {
  if [[ ! -f "$SECRETS" ]]; then
    log "generating secrets in $SECRETS"
    {
      printf "SECRET_KEY_BASE='%s'\n" "$(openssl rand -hex 64)"
      printf "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY='%s'\n" "$(openssl rand -hex 32)"
      printf "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY='%s'\n" "$(openssl rand -hex 32)"
      printf "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT='%s'\n" "$(openssl rand -hex 32)"
      printf "EMPLOYEE_SERVICE_ATTESTATION_SECRET='%s'\n" "$(openssl rand -hex 32)"
      printf "LP_OWNER_PASSWORD='%s'\n" "$(openssl rand -hex 24)"
      printf "LP_APP_PASSWORD='%s'\n" "$(openssl rand -hex 24)"
      printf "LP_STAFF_PASSWORD='%s'\n" "Lp-$(openssl rand -hex 16)"
    } >"$SECRETS"
    chmod 600 "$SECRETS"
  fi
  # shellcheck disable=SC1090
  . "$SECRETS"
  # psql reads passwords from here, so none is ever on a command line.
  printf '127.0.0.1:%s:*:%s:%s\n127.0.0.1:%s:*:payroll_app:%s\n' \
    "$PG_PORT" "$DB_OWNER" "$LP_OWNER_PASSWORD" "$PG_PORT" "$LP_APP_PASSWORD" >"$PGPASS"
  chmod 600 "$PGPASS"
}

ensure_certs() {
  local certs="$STATE/certs"
  if [[ ! -f "$certs/site.pem" ]]; then
    log "issuing a local certificate for *.$ROOT_DOMAIN with mkcert"
    # Creates mkcert's local CA on first use. Trusting it in the keychain is a
    # separate, one-time `mkcert -install` (README); servers here don't need it.
    (cd "$certs" && clean_env mkcert -cert-file site.pem -key-file site-key.pem "$ROOT_DOMAIN" "*.$ROOT_DOMAIN" >/dev/null 2>&1) || die "mkcert failed"
  fi
  # Ruby (and curl) trust the public roots plus mkcert's, so the staff API can
  # reach the employee API over HTTPS exactly as in production.
  local system_bundle
  system_bundle="$(clean_env ruby -ropenssl -e 'print OpenSSL::X509::DEFAULT_CERT_FILE')"
  cat "$system_bundle" "$(clean_env mkcert -CAROOT)/rootCA.pem" >"$certs/ca-bundle.pem"
}

refuse_dotenv_files() {
  # The API skips api/.env in local mode; a web .env would still reach Vite.
  local found
  found="$(cd "$WEB_DIR" && ls -a | grep -E '^\.env' | grep -vx '.env.example' || true)"
  [[ -z "$found" ]] || die "web/ has $(echo "$found" | tr '\n' ' ')- move it aside: local builds take only ops/local-prod's settings"
  [[ ! -f "$API_DIR/.env" ]] || warn "api/.env exists; local mode ignores it"
}

write_envs() {
  local owner_url="postgres://$DB_OWNER:$LP_OWNER_PASSWORD@127.0.0.1:$PG_PORT/$DB_NAME"
  local app_url="postgres://payroll_app:$LP_APP_PASSWORD@127.0.0.1:$PG_PORT/$DB_NAME"
  local staff_guard=log worker_guard=log expect=""
  if [[ "$PHASE" == enforced ]]; then staff_guard=raise worker_guard=raise expect="RLS_EXPECT_ENFORCED='true'"; fi

  # Every setting that decides production behaviour is pinned here; nothing
  # comes from the caller's shell or a .env file.
  {
    echo "RAILS_ENV='production'"
    echo "DEPLOYMENT_ENV='local'"
    echo "RAILS_LOG_LEVEL='info'"
    echo "AUTH_ENABLED='true'"
    echo "REQUIRE_MFA='false'"
    echo "FORCE_SSL='true'"
    echo "USE_SOLID_CACHE='true'"
    echo "USE_SOLID_QUEUE='true'"
    echo "USE_SOLID_CABLE='true'"
    grep -E '^(CLERK_SECRET_KEY|CLERK_PUBLISHABLE_KEY|CLERK_ISSUER)=' "$CLERK_ENV_FILE"
    echo "CLERK_AUTHORIZED_PARTIES='$STAFF_ORIGIN'"
    echo "CORS_ORIGINS='$STAFF_ORIGIN'"
    echo "FRONTEND_URL='$STAFF_ORIGIN'"
    echo "TENANT_ROOT_DOMAIN='$ROOT_DOMAIN'"
    echo "LOCAL_HTTPS_PORT='$HTTPS_PORT'"
    echo "TRUSTED_PROXY_CIDRS='127.0.0.1/32,::1/128'"
    echo "ACTIVE_STORAGE_SERVICE='local'"
    echo "R2_STORAGE_BACKEND='local'"
    echo "LOCAL_STORAGE_ROOT='$STATE/storage'"
    echo "LOCAL_MAIL_CAPTURE_DIR='$STATE/mail'"
    echo "RESEND_FROM_EMAIL='Cornerstone Payroll <payroll@$ROOT_DOMAIN>'"
    echo "MAILER_FROM_EMAIL='payroll@$ROOT_DOMAIN'"
    echo "PORTAL_EMAIL_NOTIFICATIONS_ENABLED='true'"
    echo "DATABASE_URL='$owner_url'"
    echo "CACHE_DATABASE_URL='$owner_url'"
    echo "QUEUE_DATABASE_URL='$owner_url'"
    echo "CABLE_DATABASE_URL='$owner_url'"
    echo "RLS_DATABASE_URL='$app_url'"
    echo "RACK_ATTACK_REDIS_URL='redis://127.0.0.1:$REDIS_PORT/0'"
    echo "SSL_CERT_FILE='$STATE/certs/ca-bundle.pem'"
    grep -E '^(SECRET_KEY_BASE|ACTIVE_RECORD_ENCRYPTION_[A-Z_]+|EMPLOYEE_SERVICE_ATTESTATION_SECRET)=' "$SECRETS"
  } >"$ENVS/common.env"

  { cat "$ENVS/common.env"
    echo "PORT='$STAFF_PORT'"; echo "PIDFILE='$RUN/staff.pid'"
    echo "SOLID_QUEUE_IN_PUMA='false'"
    echo "RLS_CONTEXT_GUARD_MODE='$staff_guard'"; echo "$expect"
    echo "EMPLOYEE_API_URL='$EMPLOYEE_API_ORIGIN'"
  } >"$ENVS/staff.env"

  { cat "$ENVS/common.env"
    echo "RLS_CONTEXT_GUARD_MODE='$worker_guard'"; echo "$expect"
    echo "EMPLOYEE_API_URL='$EMPLOYEE_API_ORIGIN'"
  } >"$ENVS/worker.env"

  { cat "$ENVS/common.env"
    echo "PORT='$EMPLOYEE_PORT'"; echo "PIDFILE='$RUN/employee.pid'"
    echo "APP_PROCESS_ROLE='employee_web'"
    echo "DB_POOL_MAX='3'"; echo "RAILS_MAX_THREADS='3'"; echo "WEB_CONCURRENCY='1'"
    echo "SOLID_QUEUE_IN_PUMA='false'"
    echo "RLS_CONTEXT_GUARD_MODE='raise'"; echo "$expect"
  } >"$ENVS/employee.env"

  # Owner maintenance (migrations, rls:*, seeding): the guard is off, so the
  # primary connection is the owner, as in the runbook's secured shell.
  { cat "$ENVS/common.env"
    echo "MIGRATION_DATABASE_URL='$owner_url'"
    echo "RLS_CONTEXT_GUARD_MODE='off'"
  } >"$ENVS/maint.env"
  chmod 600 "$ENVS"/*.env
}

start_postgres() {
  local data="$STATE/pg/data"
  if [[ ! -f "$data/PG_VERSION" ]]; then
    log "creating the private PostgreSQL 16 cluster in $data (port $PG_PORT)"
    # The bootstrap superuser reaches the cluster only through the private
    # socket directory; TCP logins need a password.
    clean_env "$PG_BIN/initdb" -D "$data" -U postgres --auth-local=trust --auth-host=scram-sha-256 -E UTF8 --locale=C >"$LOGS/initdb.log"
    cat >>"$data/postgresql.conf" <<CONF
listen_addresses = '127.0.0.1'
port = $PG_PORT
unix_socket_directories = '$STATE/pg/run'
max_connections = 100
CONF
  fi
  if ! service_alive postgres; then
    require_free_port "$PG_PORT" postgres
    clean_env "$PG_BIN/pg_ctl" -D "$data" -l "$LOGS/postgres.log" -w start >/dev/null
    claim "$(service_pid postgres)" "local-prod postgres :$PG_PORT"
  fi
  # Neon's owner bypasses RLS and can create roles; payroll_app is created
  # by the repo's role script below, through the owner, as the runbook does.
  if [[ "$(psql_super -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_OWNER'")" != 1 ]]; then
    printf "CREATE ROLE %s LOGIN CREATEDB CREATEROLE BYPASSRLS PASSWORD '%s';\n" "$DB_OWNER" "$LP_OWNER_PASSWORD" | psql_super -f -
  fi
  if [[ "$(psql_super -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")" != 1 ]]; then
    psql_super -c "CREATE DATABASE $DB_NAME OWNER $DB_OWNER"
    psql_super -d "$DB_NAME" -c "ALTER SCHEMA public OWNER TO $DB_OWNER"
  fi
}

start_redis() {
  service_alive redis && return
  require_free_port "$REDIS_PORT" redis
  clean_env redis-server --bind 127.0.0.1 --port "$REDIS_PORT" --dir "$STATE/redis" --daemonize yes \
    --pidfile "$RUN/redis.pid" --logfile "$LOGS/redis.log" --save "" --appendonly no
  wait_for redis 20 redis clean_env redis-cli -p "$REDIS_PORT" ping
  claim "$(service_pid redis)" "local-prod redis :$REDIS_PORT"
}

rails_maint() { (cd "$API_DIR" && with_env "$ENVS/maint.env" bundle exec rails "$@"); }

# The RLS phase as rls:status reports it (enforced, shadow, partial, not_installed).
rls_phase() {
  local report
  report="$(rails_maint rls:status 2>/dev/null | sed -n '/^{/,$p')"
  python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["enforcement"]["phase"])' "$report" 2>/dev/null || echo unknown
}

# The repo's role script, with its interactive \password replaced by the
# stored one. Built with shell builtins, so the password never reaches argv.
runtime_role_sql() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == '\password payroll_app' ]]; then
      printf "ALTER ROLE payroll_app PASSWORD '%s';\n" "$LP_APP_PASSWORD"
    else
      printf '%s\n' "$line"
    fi
  done <"$API_DIR/db/rls_runtime_role.sql"
}

prepare_database() {
  log "migrating with db:safe_prepare (owner connection)"
  rails_maint db:safe_prepare >"$LOGS/prepare.log" 2>&1 || die "db:safe_prepare failed (see $LOGS/prepare.log)"

  if [[ "$(owner_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'payroll_app'")" != 1 ]]; then
    log "creating payroll_app with db/rls_runtime_role.sql"
    runtime_role_sql | owner_psql -1 -f - >"$LOGS/rls_role.log" 2>&1 || die "rls_runtime_role.sql failed (see $LOGS/rls_role.log)"
  fi

  local current; current="$(rls_phase)"
  if [[ "$PHASE" == shadow && ( "$current" == enforced || "$current" == partial ) ]]; then
    die "the database is already $current; shadow needs fresh data (down.sh --purge) or rls:disable first (README)"
  fi
  log "staging RLS policies (rls:install; the database is $current)"
  rails_maint rls:install >"$LOGS/rls_install.log" 2>&1 || die "rls:install failed (see $LOGS/rls_install.log)"

  if [[ ! -f "$STATE/seeded" ]]; then
    log "seeding tax tables and consent wording (db:seed)"
    rails_maint db:seed >"$LOGS/seed.log" 2>&1 || die "db:seed failed (see $LOGS/seed.log)"
  fi
}

configure_clerk() {
  log "configuring the Clerk development instance (allowed origins, staff user)"
  local origins=("$STAFF_ORIGIN")
  for slug in "${TENANT_HOSTS[@]}"; do origins+=("https://$slug.$ROOT_DOMAIN:$HTTPS_PORT"); done
  clean_env python3 -I "$LP_DIR/clerk_setup.py" "$CLERK_ENV_FILE" "$SECRETS" "$STATE/clerk.json" "${origins[@]}" || die "Clerk setup failed"
}

bootstrap_data() {
  [[ -f "$STATE/seeded" ]] && return
  log "creating the organization, the staff login and the Harbor Finch demo companies"
  local staff_id
  staff_id="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["staff_user_id"])' "$STATE/clerk.json")"
  (cd "$API_DIR" && with_env "$ENVS/maint.env" env LP_CLERK_STAFF_USER_ID="$staff_id" LP_LEGAL_DIR="$WEB_DIR/deploy/employee/legal" \
    LP_TENANT_ORIGIN_SUFFIX=".$ROOT_DOMAIN:$HTTPS_PORT" bundle exec rails runner "$LP_DIR/bootstrap.rb") >"$LOGS/bootstrap.log" 2>&1 ||
    die "bootstrap failed (see $LOGS/bootstrap.log)"
  touch "$STATE/seeded"
}

enforce_rls() {
  if [[ "$PHASE" == enforced ]]; then
    log "enforcing RLS on every protected table (rls:enforce)"
    rails_maint rls:enforce BATCH_PAUSE=0 >"$LOGS/rls_enforce.log" 2>&1 || die "rls:enforce failed (see $LOGS/rls_enforce.log)"
  fi
}

build_web() {
  if [[ ! -x "$WEB_DIR/node_modules/.bin/vite" ]]; then
    log "installing web dependencies (npm ci)"
    (cd "$WEB_DIR" && clean_env npm ci --no-audit --no-fund) >"$LOGS/npm-ci.log" 2>&1 || die "npm ci failed (see $LOGS/npm-ci.log)"
  fi
  local publishable
  publishable="$(grep -E '^VITE_CLERK_PUBLISHABLE_KEY=' "$CLERK_ENV_FILE" | cut -d= -f2- | tr -d "'\"" || true)"
  [[ "$publishable" == pk_test_* ]] || die "VITE_CLERK_PUBLISHABLE_KEY (pk_test_) is missing from $CLERK_ENV_FILE"

  # The source fingerprint covers commits, staged and unstaged edits and
  # untracked files under web/.
  local source
  source="$( { git -C "$REPO_DIR" rev-parse HEAD; git -C "$REPO_DIR" status --porcelain=v1 -uall -- web; git -C "$REPO_DIR" diff HEAD -- web
    git -C "$REPO_DIR" ls-files -o --exclude-standard -z -- web | (cd "$REPO_DIR" && xargs -0 shasum 2>/dev/null) || true; } | shasum | cut -c1-40)"

  local surface
  for surface in staff employee; do
    local api_url="$API_ORIGIN/api/v1"
    [[ "$surface" == employee ]] && api_url="$EMPLOYEE_API_ORIGIN/api/v1"
    local build_env=(VITE_APP_SURFACE="$surface" VITE_API_URL="$api_url" VITE_AUTH_ENABLED=true
      DEPLOYMENT_ENV=local VITE_DEPLOYMENT_ENV=local VITE_TENANT_ROOT_DOMAIN="$ROOT_DOMAIN"
      VITE_PUBLIC_POSTHOG_ENABLED=false VITE_CLERK_PUBLISHABLE_KEY="$publishable")
    local stamp out="$STATE/web/$surface"
    stamp="$source-$(printf '%s\n' "${build_env[@]}" | shasum | cut -c1-40)"
    if [[ -f "$out/.built-from" && "$(cat "$out/.built-from")" == "$stamp" ]]; then continue; fi
    log "building the $surface surface (local mode)"
    (cd "$WEB_DIR" && clean_env "${build_env[@]}" npm run build) >"$LOGS/build-$surface.log" 2>&1 ||
      die "$surface build failed (see $LOGS/build-$surface.log)"
    # Swap in whole, so Caddy never serves half of a build.
    rm -rf "$out.new" "$out.old"
    cp -R "$WEB_DIR/dist" "$out.new" && echo "$stamp" >"$out.new/.built-from"
    [[ -d "$out" ]] && mv "$out" "$out.old"
    mv "$out.new" "$out" && rm -rf "$out.old"
  done
}

start_caddy() {
  python3 -I "$LP_DIR/caddyfile.py" "$STATE" "$ROOT_DOMAIN" "$HTTPS_PORT" "$STAFF_PORT" "$EMPLOYEE_PORT" "$CADDY_ADMIN" >"$STATE/Caddyfile"
  clean_env caddy validate --config "$STATE/Caddyfile" --adapter caddyfile >"$LOGS/caddy-validate.log" 2>&1 || die "Caddyfile invalid (see $LOGS/caddy-validate.log)"
  if service_alive caddy; then
    clean_env caddy reload --config "$STATE/Caddyfile" --adapter caddyfile --address "$CADDY_ADMIN" >/dev/null
    return
  fi
  require_free_port "$HTTPS_PORT" caddy
  require_free_port "$CADDY_ADMIN_PORT" "caddy admin"
  clean_env XDG_DATA_HOME="$STATE/caddy" XDG_CONFIG_HOME="$STATE/caddy" caddy start --config "$STATE/Caddyfile" --adapter caddyfile \
    --pidfile "$RUN/caddy.pid" >"$LOGS/caddy-start.log" 2>&1 || die "caddy failed to start (see $LOGS/caddy-start.log)"
  service_alive caddy || die "caddy did not stay up (see $LOGS/caddy-start.log)"
  claim "$(service_pid caddy)" "local-prod caddy :$HTTPS_PORT"
}

start_rails() {
  local name="$1" port="$2" envfile="$ENVS/$1.env" pidfile="$RUN/$1.pid"; shift 2
  local old; old="$(service_pid "$name")"
  if [[ -n "$old" ]]; then
    kill "$old" 2>/dev/null || true
    for _ in {1..30}; do kill -0 "$old" 2>/dev/null || break; sleep 1; done
    kill -0 "$old" 2>/dev/null && die "$name ($old) did not stop; not starting a second copy"
    release "$old"
  fi
  rm -f "$pidfile"
  [[ -z "$port" ]] || require_free_port "$port" "$name"
  # One process per service: the shell records its own pid and execs the
  # app, and nothing holds this script's output open after it exits.
  (cd "$API_DIR" && exec env -i HOME="$HOME" USER="${USER:-}" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
    ${RBENV_VERSION:+RBENV_VERSION="$RBENV_VERSION"} \
    nohup bash -c 'echo $$ >"$1"; set -a; . "$2"; set +a; shift 2; exec "$@"' _ "$pidfile" "$envfile" "$@") \
    >>"$LOGS/$name.log" 2>&1 </dev/null &
  for _ in {1..30}; do [[ -s "$pidfile" ]] && break; sleep 1; done
  service_alive "$name" || die "$name did not start (see $LOGS/$name.log)"
  claim "$(service_pid "$name")" "local-prod $name"
}

up_ok() { curl_local -o /dev/null "$1/up"; }
dependencies_ok() { [[ "$(curl_local "$EMPLOYEE_API_ORIGIN/health/dependencies" 2>/dev/null)" == *'"status":"ok"'* ]]; }

start_processes() {
  log "starting staff web (:$STAFF_PORT), worker and employee API (:$EMPLOYEE_PORT)"
  # Loopback only: Caddy is the one way in, as Render's proxy is.
  start_rails employee "$EMPLOYEE_PORT" bundle exec puma -C config/puma.rb -b "tcp://127.0.0.1:$EMPLOYEE_PORT"
  start_rails staff "$STAFF_PORT" bundle exec puma -C config/puma.rb -b "tcp://127.0.0.1:$STAFF_PORT"
  start_rails worker "" bin/jobs
  wait_for "employee API" 120 employee up_ok "$EMPLOYEE_API_ORIGIN"
  wait_for "staff web" 120 staff up_ok "$API_ORIGIN"
  # The employee API's dependency health includes the worker's heartbeat.
  wait_for "worker heartbeat" 180 worker dependencies_ok
}

require_tools
ensure_dirs
# Refuse before rewriting any env file; prepare_database checks the database too.
if [[ "$PHASE" == shadow && "$(cat "$STATE/phase" 2>/dev/null)" == enforced ]]; then
  die "this copy is enforced; shadow needs fresh data (down.sh --purge) or rls:disable first (README)"
fi
ensure_secrets
refuse_dotenv_files
ensure_certs
write_envs
start_postgres
start_redis
prepare_database
configure_clerk
bootstrap_data
enforce_rls
build_web
start_caddy
start_processes
echo "$PHASE" >"$STATE/phase"
log "up. Smoke checks: ops/local-prod/smoke.sh   Stop: ops/local-prod/down.sh"
log "staff: $STAFF_ORIGIN   employee app: https://harborfinch.$ROOT_DOMAIN:$HTTPS_PORT"
