#!/usr/bin/env bash
# Run from api/. Keep the same partitions/reports as the former Actions matrix.
set -euo pipefail
pids=()
cleanup() {
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT
for shard in 1 2 3; do
  (
    export DATABASE_URL="postgres://postgres:postgres@127.0.0.1:5432/cornerstone_payroll_ci_${shard}_test"
    export TEST_DATABASE_URL="$DATABASE_URL"
    export TEST_STORAGE_ROOT="$PWD/tmp/quality-storage-$shard"
    createdb --host 127.0.0.1 --username postgres "cornerstone_payroll_ci_${shard}_test"
    bundle exec rails db:schema:load db:integrity
    RLS_CONTEXT_GUARD_MODE=raise python3 ../.github/scripts/quality_rspec.py run --shard "$shard" --count 3 \
      --directory ../tmp/quality-rspec/results --timings ../tmp/quality-rspec/timings.json
  ) &
  pids+=("$!")
done
# Wait for every worker, including when an earlier worker failed.
status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
exit "$status"
