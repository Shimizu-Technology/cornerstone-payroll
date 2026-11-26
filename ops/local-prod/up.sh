#!/usr/bin/env bash
# Bring up the local production copy: one command, safe to rerun.
#
#   ops/local-prod/up.sh                 # RLS enforced (the default)
#   LOCAL_PROD_RLS_PHASE=shadow ops/local-prod/up.sh
#
# See ops/local-prod/README.md for what runs and how to reach it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PHASE="${LOCAL_PROD_RLS_PHASE:-enforced}"
[[ "$PHASE" == enforced || "$PHASE" == shadow ]] || die "LOCAL_PROD_RLS_PHASE must be enforced or shadow"

ensure_secrets() {
  [[ -f "$SECRETS" ]] && return
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
}

ensure_certs() {
  local certs="$STATE/certs"
  if [[ ! -f "$certs/site.pem" ]]; then
    log "issuing a local certificate for *.$ROOT_DOMAIN with mkcert"
    # Creates mkcert's local CA on first use. Trusting it in the keychain is a
    # separate, one-time `mkcert -install` (README); servers here don't need it.
    (cd "$certs" && mkcert -cert-file site.pem -key-file site-key.pem "$ROOT_DOMAIN" "*.$ROOT_DOMAIN" >/dev/null 2>&1) || die "mkcert failed"
  fi
  # Ruby (and curl) trust the public roots plus mkcert's, so the staff API can
  # reach the employee API over HTTPS exactly as in production.
  local system_bundle
  system_bundle="$(clean_env ruby -ropenssl -e 'print OpenSSL::X509::DEFAULT_CERT_FILE')"
  cat "$system_bundle" "$(mkcert -CAROOT)/rootCA.pem" >"$certs/ca-bundle.pem"
}

write_envs() {
  # shellcheck disable=SC1090
  . "$SECRETS"
  local owner_url="postgres://$DB_OWNER:$LP_OWNER_PASSWORD@127.0.0.1:$PG_PORT/$DB_NAME"
  local app_url="postgres://payroll_app:$LP_APP_PASSWORD@127.0.0.1:$PG_PORT/$DB_NAME"
  local staff_guard=log worker_guard=log expect=""
  if [[ "$PHASE" == enforced ]]; then staff_guard=raise worker_guard=raise expect="RLS_EXPECT_ENFORCED='true'"; fi

  {
    echo "RAILS_ENV='production'"
    echo "DEPLOYMENT_ENV='local'"
    echo "RAILS_LOG_LEVEL='info'"
    echo "AUTH_ENABLED='true'"
    echo "REQUIRE_MFA='false'"
    grep -E '^(CLERK_SECRET_KEY|CLERK_PUBLISHABLE_KEY|CLERK_ISSUER)=' "$CLERK_ENV_FILE"
    echo "CLERK_AUTHORIZED_PARTIES='$STAFF_ORIGIN'"
    echo "CORS_ORIGINS='$STAFF_ORIGIN'"
    echo "FRONTEND_URL='$STAFF_ORIGIN'"
    echo "TENANT_ROOT_DOMAIN='$ROOT_DOMAIN'"
    echo "LOCAL_HTTPS_PORT='$HTTPS_PORT'"
    echo "TRUSTED_PROXY_CIDRS='127.0.0.1/32,::1/128'"
    echo "ACTIVE_STORAGE_SERVICE='local'"
    echo "R2_STORAGE_BACKEND='local'"
    echo "LOCAL_MAIL_CAPTURE_DIR='$STATE/mail'"
    echo "RESEND_FROM_EMAIL='Cornerstone Payroll <payroll@$ROOT_DOMAIN>'"
    echo "MAILER_FROM_EMAIL='payroll@$ROOT_DOMAIN'"
    echo "PORTAL_EMAIL_NOTIFICATIONS_ENABLED='true'"
    echo "DATABASE_URL='$owner_url'"
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
  if ! clean_env "$PG_BIN/pg_ctl" -D "$data" status >/dev/null 2>&1; then
    clean_env "$PG_BIN/pg_ctl" -D "$data" -l "$LOGS/postgres.log" -w start >/dev/null
    claim "$(head -1 "$data/postmaster.pid")" "local-prod postgres :$PG_PORT"
  fi
  # shellcheck disable=SC1090
  . "$SECRETS"
  # Neon's owner bypasses RLS and can create roles; payroll_app is created
  # by the repo's role script below, through the owner, as the runbook does.
  if [[ "$(psql_super -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_OWNER'")" != 1 ]]; then
    psql_super -c "CREATE ROLE $DB_OWNER LOGIN CREATEDB CREATEROLE BYPASSRLS PASSWORD '$LP_OWNER_PASSWORD'"
  fi
  if [[ "$(psql_super -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")" != 1 ]]; then
    psql_super -c "CREATE DATABASE $DB_NAME OWNER $DB_OWNER"
    psql_super -d "$DB_NAME" -c "ALTER SCHEMA public OWNER TO $DB_OWNER"
  fi
}

start_redis() {
  pid_alive "$RUN/redis.pid" && return
  clean_env redis-server --bind 127.0.0.1 --port "$REDIS_PORT" --dir "$STATE/redis" --daemonize yes \
    --pidfile "$RUN/redis.pid" --logfile "$LOGS/redis.log" --save "" --appendonly no
  wait_for redis 20 clean_env redis-cli -p "$REDIS_PORT" ping
  claim "$(cat "$RUN/redis.pid")" "local-prod redis :$REDIS_PORT"
}

owner_psql() {
  # shellcheck disable=SC1090
  . "$SECRETS"
  clean_env PGPASSWORD="$LP_OWNER_PASSWORD" "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PG_PORT" -U "$DB_OWNER" -d "$DB_NAME" "$@"
}

rails_maint() { (cd "$API_DIR" && with_env "$ENVS/maint.env" bundle exec rails "$@"); }

prepare_database() {
  log "migrating with db:safe_prepare (owner connection)"
  rails_maint db:safe_prepare >"$LOGS/prepare.log" 2>&1 || die "db:safe_prepare failed (see $LOGS/prepare.log)"

  if [[ "$(owner_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'payroll_app'")" != 1 ]]; then
    log "creating payroll_app with db/rls_runtime_role.sql"
    # The repo script, with its interactive \password replaced by a stored one.
    # shellcheck disable=SC1090
    . "$SECRETS"
    sed "s|^\\\\password payroll_app\$|ALTER ROLE payroll_app PASSWORD :'app_password';|" "$API_DIR/db/rls_runtime_role.sql" |
      owner_psql -v app_password="$LP_APP_PASSWORD" -f - >"$LOGS/rls_role.log" 2>&1 || die "rls_runtime_role.sql failed (see $LOGS/rls_role.log)"
  fi

  log "staging RLS policies (rls:install, shadow)"
  rails_maint rls:install >"$LOGS/rls_install.log" 2>&1 || die "rls:install failed (see $LOGS/rls_install.log)"

  if [[ ! -f "$STATE/seeded" ]]; then
    log "seeding tax tables and consent wording (db:seed)"
    rails_maint db:seed >"$LOGS/seed.log" 2>&1 || die "db:seed failed (see $LOGS/seed.log)"
  fi
}

configure_clerk() {
  log "configuring the Clerk development instance (allowed origins, staff user)"
  # shellcheck disable=SC1090
  . "$SECRETS"
  local origins=("$STAFF_ORIGIN")
  for slug in "${TENANT_HOSTS[@]}"; do origins+=("https://$slug.$ROOT_DOMAIN:$HTTPS_PORT"); done
  clean_env LP_STAFF_PASSWORD="$LP_STAFF_PASSWORD" CLERK_ENV_FILE="$CLERK_ENV_FILE" \
    python3 -I "$LP_DIR/clerk_setup.py" "$STATE/clerk.json" "${origins[@]}" || die "Clerk setup failed"
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
  local sha surface
  sha="$(git -C "$REPO_DIR" rev-parse HEAD)$(git -C "$REPO_DIR" diff --quiet -- web || echo -dirty)"
  if [[ ! -x "$WEB_DIR/node_modules/.bin/vite" ]]; then
    log "installing web dependencies (npm ci)"
    (cd "$WEB_DIR" && clean_env npm ci --no-audit --no-fund) >"$LOGS/npm-ci.log" 2>&1 || die "npm ci failed (see $LOGS/npm-ci.log)"
  fi
  for surface in staff employee; do
    local out="$STATE/web/$surface"
    if [[ -f "$out/.built-from" && "$(cat "$out/.built-from")" == "$sha" && "$sha" != *-dirty ]]; then continue; fi
    log "building the $surface surface (local mode)"
    local api_url="$API_ORIGIN/api/v1"
    [[ "$surface" == employee ]] && api_url="$EMPLOYEE_API_ORIGIN/api/v1"
    (cd "$WEB_DIR" && clean_env VITE_APP_SURFACE="$surface" VITE_API_URL="$api_url" VITE_AUTH_ENABLED=true \
      DEPLOYMENT_ENV=local VITE_DEPLOYMENT_ENV=local VITE_TENANT_ROOT_DOMAIN="$ROOT_DOMAIN" \
      VITE_CLERK_PUBLISHABLE_KEY="$(grep -E '^VITE_CLERK_PUBLISHABLE_KEY=' "$CLERK_ENV_FILE" | cut -d= -f2- | tr -d "'\"")" \
      npm run build) >"$LOGS/build-$surface.log" 2>&1 || die "$surface build failed (see $LOGS/build-$surface.log)"
    rm -rf "$out" && cp -R "$WEB_DIR/dist" "$out" && echo "$sha" >"$out/.built-from"
  done
}

start_caddy() {
  python3 -I "$LP_DIR/caddyfile.py" "$STATE" "$ROOT_DOMAIN" "$HTTPS_PORT" "$STAFF_PORT" "$EMPLOYEE_PORT" "$CADDY_ADMIN" >"$STATE/Caddyfile"
  clean_env caddy validate --config "$STATE/Caddyfile" --adapter caddyfile >"$LOGS/caddy-validate.log" 2>&1 || die "Caddyfile invalid (see $LOGS/caddy-validate.log)"
  if pid_alive "$RUN/caddy.pid"; then
    clean_env caddy reload --config "$STATE/Caddyfile" --adapter caddyfile --address "$CADDY_ADMIN" >/dev/null
    return
  fi
  clean_env XDG_DATA_HOME="$STATE/caddy" XDG_CONFIG_HOME="$STATE/caddy" caddy start --config "$STATE/Caddyfile" --adapter caddyfile \
    --pidfile "$RUN/caddy.pid" >"$LOGS/caddy-start.log" 2>&1 || die "caddy failed to start (see $LOGS/caddy-start.log)"
  claim "$(cat "$RUN/caddy.pid")" "local-prod caddy :$HTTPS_PORT"
}

start_rails() {
  local name="$1" envfile="$ENVS/$1.env"; shift
  if pid_alive "$RUN/$name.pid"; then
    kill "$(cat "$RUN/$name.pid")" 2>/dev/null || true
    for _ in {1..30}; do pid_alive "$RUN/$name.pid" || break; sleep 1; done
  fi
  # One process per service: the subshell execs, and nothing keeps this
  # script's output open after it exits.
  (cd "$API_DIR" && exec nohup bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$RUN/$name.pid" \
    env -i HOME="$HOME" USER="${USER:-}" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
    bash -c 'set -a; . "$1"; set +a; shift; exec "$@"' _ "$envfile" "$@") >>"$LOGS/$name.log" 2>&1 </dev/null &
  for _ in {1..30}; do [[ -s "$RUN/$name.pid" ]] && break; sleep 1; done
  [[ -s "$RUN/$name.pid" ]] || die "$name did not start (see $LOGS/$name.log)"
  claim "$(cat "$RUN/$name.pid")" "local-prod $name"
}

start_processes() {
  log "starting staff web (:$STAFF_PORT), worker and employee API (:$EMPLOYEE_PORT)"
  # Loopback only: Caddy is the one way in, as Render's proxy is.
  start_rails employee bundle exec puma -C config/puma.rb -b "tcp://127.0.0.1:$EMPLOYEE_PORT"
  start_rails staff bundle exec puma -C config/puma.rb -b "tcp://127.0.0.1:$STAFF_PORT"
  start_rails worker bin/jobs
  wait_for "employee API" 90 curl -fsS "http://127.0.0.1:$EMPLOYEE_PORT/up"
  wait_for "staff web" 90 curl -fsS "http://127.0.0.1:$STAFF_PORT/up"
  # The employee API's dependency health includes the worker's heartbeat.
  wait_for "worker heartbeat" 180 bash -c "curl -fsS --cacert '$STATE/certs/ca-bundle.pem' '$EMPLOYEE_API_ORIGIN/health/dependencies' | grep -q '\"status\":\"ok\"'"
}

require_tools
ensure_dirs
ensure_secrets
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
