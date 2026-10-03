#!/usr/bin/env bash
set -euo pipefail

candidates_only=0
if [[ "${1:-}" == "--candidate-workflows-only" ]]; then
  candidates_only=1
  shift
fi
payroll_sha="${1:-}"
aire_sha="${2:-}"
requested_run_id="${3:-}"
for value in "${payroll_sha}" "${aire_sha}"; do
  [[ "${value}" =~ ^[0-9a-f]{40}$ ]] || { echo "A certificate requires two full commit SHAs." >&2; exit 64; }
done
[[ -z "${requested_run_id}" || "${requested_run_id}" =~ ^[1-9][0-9]*$ ]] || exit 64

repo="Shimizu-Technology/cornerstone-payroll"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/connected-payroll-certificate.XXXXXX")"
trap 'rm -rf -- "${temporary_dir}"' EXIT

verify_candidate_workflow() {
  local candidate_repo="$1" workflow="$2" sha="$3" attempt run_id
  local prefix="${temporary_dir}/${candidate_repo}"
  if [[ "${candidate_repo}" == "aire-services" && "${AIRE_ACTIONS_PUBLIC_READ:-false}" == "true" ]]; then
    python3 "${script_dir}/public_aire_actions.py" runs "${sha}" > "${prefix}-runs.json"
  else
    gh run list --repo "Shimizu-Technology/${candidate_repo}" --workflow "${workflow}" \
      --branch staging-v2 --event push --commit "${sha}" --limit 100 \
      --json databaseId,headSha,createdAt > "${prefix}-runs.json"
  fi
  run_id="$(python3 - "${prefix}-runs.json" "${sha}" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1]))
matches = sorted((run for run in runs if run.get("headSha") == sys.argv[2]),
                 key=lambda run: run["createdAt"], reverse=True)
if not matches or not isinstance(matches[0].get("databaseId"), int) or matches[0]["databaseId"] < 1:
    sys.exit("An immutable candidate has no exact-SHA staging push workflow; deployment held.")
print(matches[0]["databaseId"])
PY
)"
  if [[ "${candidate_repo}" == "aire-services" && "${AIRE_ACTIONS_PUBLIC_READ:-false}" == "true" ]]; then
    python3 "${script_dir}/public_aire_actions.py" run "${run_id}" > "${prefix}-run.json"
  else
    gh api "repos/Shimizu-Technology/${candidate_repo}/actions/runs/${run_id}" > "${prefix}-run.json"
  fi
  attempt="$(python3 - "${prefix}-run.json" "${sha}" "${workflow}" "${run_id}" <<'PY'
import json, sys
run = json.load(open(sys.argv[1]))
# GitHub run.name follows run-name when configured; the exact workflow path
# identifies this workflow independently of its presentation title.
expected = {"id": int(sys.argv[4]), "event": "push", "head_branch": "staging-v2",
            "head_sha": sys.argv[2], "path": ".github/workflows/" + sys.argv[3],
            "status": "completed", "conclusion": "success"}
if any(run.get(key) != value for key, value in expected.items()):
    sys.exit("Candidate quality or image workflow is pending, failed, or mismatched; deployment held.")
attempt = run.get("run_attempt")
if not isinstance(attempt, int) or attempt < 1:
    sys.exit("Candidate workflow has no valid current attempt; deployment held.")
print(attempt)
PY
)"
  if [[ "${candidate_repo}" == "aire-services" && "${AIRE_ACTIONS_PUBLIC_READ:-false}" == "true" ]]; then
    python3 "${script_dir}/public_aire_actions.py" jobs "${run_id}" "${attempt}" > "${prefix}-jobs.json"
  else
    gh api --paginate --slurp \
      "repos/Shimizu-Technology/${candidate_repo}/actions/runs/${run_id}/attempts/${attempt}/jobs?per_page=100" > "${prefix}-jobs.json"
  fi
  python3 - "${prefix}-jobs.json" "${candidate_repo}" <<'PY'
import json, sys
pages = json.load(open(sys.argv[1]))
jobs = [job for page in pages for job in page["jobs"]]
required = {
    "cornerstone-payroll": ["backend", "frontend", "browser", "Staging v2 configuration",
        "Publish staging v2 images (cornerstone-payroll-api, api, api/Dockerfile)",
        "Publish staging v2 images (cornerstone-payroll-web, web, web/Dockerfile)"],
    "aire-services": ["backend", "frontend", "staging-configuration", "publish-gate",
        "publish (aire-services-api, backend, backend/Dockerfile)",
        "publish (aire-services-web, frontend, frontend/Dockerfile)"],
}[sys.argv[2]]
for name in required:
    matches = [job for job in jobs if job.get("name") == name]
    if len(matches) != 1 or matches[0].get("status") != "completed" or matches[0].get("conclusion") != "success":
        sys.exit("Exact candidate quality gates and both image publications must succeed; deployment held.")
PY
}

# The HTTP certificate alone does not prove the candidates' ordinary gates or
# image publication. Apply these same exact-SHA prerequisites in CI and on every
# direct/manual deployment, independent of the dispatch workflow's own revision.
verify_candidate_workflow cornerstone-payroll quality.yml "${payroll_sha}"
verify_candidate_workflow aire-services staging-v2.yml "${aire_sha}"
if [[ "${candidates_only}" == "1" ]]; then
  echo "Both immutable candidates passed staging push quality gates and image publication."
  exit 0
fi

if [[ -z "${requested_run_id}" ]]; then
  if ! gh run list --repo "${repo}" --workflow quality.yml \
      --branch staging-v2 --event workflow_dispatch --limit 100 \
      --json databaseId,displayTitle,createdAt > "${temporary_dir}/runs.json"; then
    echo "Unable to retrieve connected-payroll certificates; deployment held." >&2
    exit 1
  fi
  requested_run_id="$(python3 - "${temporary_dir}/runs.json" "${payroll_sha}" "${aire_sha}" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1]))
title = f"Connected payroll {sys.argv[2]} + {sys.argv[3]}"
matches = sorted((run for run in runs if run.get("displayTitle") == title),
                 key=lambda run: run["createdAt"], reverse=True)
if matches:
    print(matches[0]["databaseId"])
PY
)"
fi
if [[ -z "${requested_run_id}" ]]; then
  echo "This commit pair has no connected-payroll certificate; deployment held." >&2
  exit 1
fi

gh api "repos/${repo}/actions/runs/${requested_run_id}" > "${temporary_dir}/run.json"
run_attempt="$(python3 - "${temporary_dir}/run.json" "${payroll_sha}" "${aire_sha}" "${requested_run_id}" <<'PY'
import json, sys
run = json.load(open(sys.argv[1]))
expected = {
    "id": int(sys.argv[4]), "status": "completed", "conclusion": "success",
    "event": "workflow_dispatch", "head_branch": "staging-v2",
    "path": ".github/workflows/quality.yml",
    "display_title": f"Connected payroll {sys.argv[2]} + {sys.argv[3]}",
}
if any(run.get(key) != value for key, value in expected.items()):
    sys.exit("Connected-payroll certification is pending, failed, or does not match; deployment held.")
attempt = run.get("run_attempt")
if not isinstance(attempt, int) or attempt < 1:
    sys.exit("Invalid connected-payroll run attempt; deployment held.")
print(attempt)
PY
)"
gh run download "${requested_run_id}" --repo "${repo}" \
  --name "connected-payroll-pair-${requested_run_id}-${run_attempt}" \
  --dir "${temporary_dir}/certificate" >/dev/null

python3 - "${temporary_dir}/run.json" "${temporary_dir}/certificate/pair-certificate.json" \
    "${payroll_sha}" "${aire_sha}" <<'PY'
import json, sys
run = json.load(open(sys.argv[1]))
certificate = json.load(open(sys.argv[2]))
expected = {
    "schema_version": 1, "certification": "passed", "lane": "real-http-synthetic-v1",
    "payroll_sha": sys.argv[3], "aire_sha": sys.argv[4],
    "workflow_sha": run["head_sha"], "run_id": run["id"], "run_attempt": run["run_attempt"],
}
if certificate != expected:
    sys.exit("Connected-payroll certificate evidence does not match this run and pair; deployment held.")
print(run["id"])
PY
