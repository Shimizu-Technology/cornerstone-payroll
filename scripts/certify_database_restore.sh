#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
API_DIR="$ROOT_DIR/api"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
SOURCE_DATABASE="cornerstone_recovery_src_${RUN_ID//-/_}"
RESTORE_DATABASE="cornerstone_recovery_dst_${RUN_ID//-/_}"
TEMP_PARENT="${TMPDIR:-/tmp}"
while [[ "$TEMP_PARENT" != "/" && "$TEMP_PARENT" == */ ]]; do
  TEMP_PARENT="${TEMP_PARENT%/}"
done
TEMP_DIR="$(mktemp -d "$TEMP_PARENT/cornerstone-database-recovery.XXXXXX")"
FIXTURE_PATH="$TEMP_DIR/release.json"
BACKUP_PATH="$TEMP_DIR/backup.dump"
RBENV_ROOT="$(rbenv root 2>/dev/null || true)"

fail() {
  echo "Database recovery certification failed: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  dropdb --if-exists "$RESTORE_DATABASE" >/dev/null 2>&1 || true
  dropdb --if-exists "$SOURCE_DATABASE" >/dev/null 2>&1 || true
  if [[ -d "$TEMP_DIR" ]] && ! /usr/bin/trash "$TEMP_DIR" 2>/dev/null; then
    if [[ "$TEMP_DIR" == "$TEMP_PARENT"/cornerstone-database-recovery.* ]]; then
      /bin/rm -rf -- "$TEMP_DIR"
    else
      echo "Refusing to remove unexpected database-certification path: $TEMP_DIR" >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

[[ -n "$RBENV_ROOT" && -d "$RBENV_ROOT/shims" ]] || fail "rbenv is required"
[[ "$SOURCE_DATABASE" == cornerstone_recovery_src_* ]] || fail "unsafe source database name"
[[ "$RESTORE_DATABASE" == cornerstone_recovery_dst_* ]] || fail "unsafe restore database name"

export PATH="$RBENV_ROOT/shims:$PATH"
export RAILS_ENV=test
export E2E_TEST_MODE=true
export TEST_DATABASE_URL="postgresql:///$SOURCE_DATABASE"
export DATABASE_URL="$TEST_DATABASE_URL"
export E2E_FIXTURE_PATH="$FIXTURE_PATH"

createdb "$SOURCE_DATABASE"
cd "$API_DIR"
bundle exec rails db:schema:load db:seed >/dev/null
bundle exec rails e2e:seed >/dev/null

count_query="SELECT json_build_object(
  'companies',(SELECT count(*) FROM companies),
  'employees',(SELECT count(*) FROM employees),
  'pay_periods',(SELECT count(*) FROM pay_periods),
  'payroll_items',(SELECT count(*) FROM payroll_items),
  'audit_logs',(SELECT count(*) FROM audit_logs),
  'filing_records',(SELECT count(*) FROM payroll_filing_records),
  'queue_probes',(SELECT count(*) FROM operational_queue_probes)
);"
digest_query="SELECT md5(coalesce(string_agg(payload, E'\\n' ORDER BY payload), ''))
FROM (
  SELECT 'companies:' || to_jsonb(companies)::text AS payload FROM companies
  UNION ALL SELECT 'employees:' || to_jsonb(employees)::text FROM employees
  UNION ALL SELECT 'pay_periods:' || to_jsonb(pay_periods)::text FROM pay_periods
  UNION ALL SELECT 'payroll_items:' || to_jsonb(payroll_items)::text FROM payroll_items
  UNION ALL SELECT 'audit_logs:' || to_jsonb(audit_logs)::text FROM audit_logs
  UNION ALL SELECT 'payroll_filing_records:' || to_jsonb(payroll_filing_records)::text FROM payroll_filing_records
  UNION ALL SELECT 'operational_queue_probes:' || to_jsonb(operational_queue_probes)::text FROM operational_queue_probes
) AS recovery_rows;"

source_counts="$(psql -At -d "$SOURCE_DATABASE" -c "$count_query")"
source_migrations="$(psql -At -d "$SOURCE_DATABASE" -c "SELECT coalesce(string_agg(version, ',' ORDER BY version), '') FROM schema_migrations;")"
source_digest="$(psql -At -d "$SOURCE_DATABASE" -c "$digest_query")"

pg_dump -Fc --no-owner --no-privileges -f "$BACKUP_PATH" "$SOURCE_DATABASE"
backup_sha="$(shasum -a 256 "$BACKUP_PATH" | awk '{print $1}')"
backup_bytes="$(stat -f '%z' "$BACKUP_PATH")"

createdb "$RESTORE_DATABASE"
pg_restore --no-owner --no-privileges -d "$RESTORE_DATABASE" "$BACKUP_PATH"

restore_counts="$(psql -At -d "$RESTORE_DATABASE" -c "$count_query")"
restore_migrations="$(psql -At -d "$RESTORE_DATABASE" -c "SELECT coalesce(string_agg(version, ',' ORDER BY version), '') FROM schema_migrations;")"
restore_digest="$(psql -At -d "$RESTORE_DATABASE" -c "$digest_query")"

[[ "$source_counts" == "$restore_counts" ]] || fail "application record counts differ after restore"
[[ "$source_migrations" == "$restore_migrations" ]] || fail "schema migration identity differs after restore"
[[ "$source_digest" == "$restore_digest" ]] || fail "application record contents differ after restore"

migration_count="$(psql -At -d "$SOURCE_DATABASE" -c 'SELECT count(*) FROM schema_migrations;')"
migration_head="$(psql -At -d "$SOURCE_DATABASE" -c 'SELECT max(version) FROM schema_migrations;')"
migration_set_sha="$(printf '%s' "$source_migrations" | shasum -a 256 | awk '{print $1}')"

echo "LOCAL DATABASE RECOVERY CERTIFICATION PASSED"
echo "backup_bytes=$backup_bytes"
echo "backup_sha256=$backup_sha"
echo "source_counts=$source_counts"
echo "restore_counts=$restore_counts"
echo "record_digest=$source_digest"
echo "schema_migrations=$migration_count:$migration_head"
echo "schema_migration_set_sha256=$migration_set_sha"
