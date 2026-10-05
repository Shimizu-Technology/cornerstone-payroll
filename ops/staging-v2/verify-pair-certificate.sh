#!/usr/bin/env bash
set -euo pipefail

candidates_only=0
if [[ "${1:-}" == "--candidate-workflows-only" ]]; then candidates_only=1; shift; fi
payroll_sha="${1:-}"
aire_sha="${2:-}"
requested_run_id="${3:-}"
automatic_certificate=0
[[ -n "${requested_run_id}" ]] || automatic_certificate=1
for value in "${payroll_sha}" "${aire_sha}"; do
  [[ "${value}" =~ ^[0-9a-f]{40}$ ]] || { echo "A certificate requires two full commit SHAs." >&2; exit 64; }
done
[[ -z "${requested_run_id}" || "${requested_run_id}" =~ ^[1-9][0-9]*$ ]] || exit 64
repo="Shimizu-Technology/cornerstone-payroll"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="${script_dir}/pair_evidence.py"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/connected-payroll-certificate.XXXXXX")"
trap 'rm -rf -- "${temporary_dir}"' EXIT

candidate_run() {
  if [[ "$1" == aire-services && "${AIRE_ACTIONS_PUBLIC_READ:-false}" == true ]]; then
    python3 "${script_dir}/public_aire_actions.py" run "$2"
  else
    gh api "repos/Shimizu-Technology/$1/actions/runs/$2"
  fi
}

candidate_inventory() {
  if [[ "$1" == aire-services && "${AIRE_ACTIONS_PUBLIC_READ:-false}" == true ]]; then
    python3 "${script_dir}/public_aire_actions.py" runs "$3" || {
      echo "Candidate $1: public workflow inventory unavailable; deployment held." >&2; return 1;
    }
  else
    # Use the scoped REST endpoint directly, without gh run list's implicit
    # exclude_pull_requests filter or workflow-name/ID translation.
    gh api --paginate --slurp "repos/Shimizu-Technology/$1/actions/workflows/$2/runs?branch=staging-v2&event=push&head_sha=$3&per_page=100" || {
      echo "Candidate $1: workflow inventory unavailable; deployment held." >&2; return 1;
    }
  fi
}

verify_candidate_workflow() {
  local candidate_repo="$1" workflow="$2" sha="$3" attempt run_id
  local prefix="${temporary_dir}/${candidate_repo}"
  candidate_inventory "${candidate_repo}" "${workflow}" "${sha}" > "${prefix}-runs.json"
  run_id="$(python3 "${validator}" candidate "${prefix}-runs.json" "${sha}" "${workflow}")" || {
    echo "Candidate ${candidate_repo}: exact workflow inventory rejected; deployment held." >&2; return 1;
  }
  candidate_run "${candidate_repo}" "${run_id}" > "${prefix}-run.json" || {
    echo "Candidate ${candidate_repo}: selected run unavailable; deployment held." >&2; return 1;
  }
  attempt="$(python3 "${validator}" candidate-run "${prefix}-run.json" "${prefix}-runs.json" "${sha}" "${workflow}" "${run_id}")" || {
    echo "Candidate ${candidate_repo}: selected workflow or attempt rejected; deployment held." >&2; return 1;
  }
  if [[ "${candidate_repo}" == aire-services && "${AIRE_ACTIONS_PUBLIC_READ:-false}" == true ]]; then
    python3 "${script_dir}/public_aire_actions.py" jobs "${run_id}" "${attempt}" > "${prefix}-jobs.json" || {
      echo "Candidate ${candidate_repo}: public current-attempt jobs unavailable; deployment held." >&2; return 1;
    }
  else
    gh api --paginate --slurp "repos/Shimizu-Technology/${candidate_repo}/actions/runs/${run_id}/attempts/${attempt}/jobs?per_page=100" > "${prefix}-jobs.json" || {
      echo "Candidate ${candidate_repo}: current-attempt jobs unavailable; deployment held." >&2; return 1;
    }
  fi
  python3 "${validator}" jobs "${prefix}-jobs.json" "${candidate_repo}" "${prefix}-run.json" || {
    echo "Candidate ${candidate_repo}: quality or image job evidence rejected; deployment held." >&2; return 1;
  }
  candidate_run "${candidate_repo}" "${run_id}" > "${prefix}-recheck.json" || {
    echo "Candidate ${candidate_repo}: final current-attempt check unavailable; deployment held." >&2; return 1;
  }
  candidate_inventory "${candidate_repo}" "${workflow}" "${sha}" > "${prefix}-latest-runs.json"
  [[ "$(python3 "${validator}" candidate "${prefix}-latest-runs.json" "${sha}" "${workflow}")" == "${run_id}" ]] || {
    echo "Candidate ${candidate_repo}: newest workflow changed during verification; deployment held." >&2; return 1;
  }
  python3 "${validator}" candidate-run "${prefix}-recheck.json" "${prefix}-latest-runs.json" "${sha}" "${workflow}" "${run_id}" > /dev/null || {
    echo "Candidate ${candidate_repo}: final inventory attempt changed; deployment held." >&2; return 1;
  }
  python3 "${validator}" unchanged "${prefix}-run.json" "${prefix}-recheck.json" || {
    echo "Candidate ${candidate_repo}: workflow changed during verification; deployment held." >&2; return 1;
  }
}

verify_candidate_workflow cornerstone-payroll quality.yml "${payroll_sha}"
verify_candidate_workflow aire-services staging-v2.yml "${aire_sha}"
if [[ "${candidates_only}" == 1 ]]; then
  echo "Both immutable candidates passed staging push quality gates and image publication."
  exit 0
fi
if [[ -z "${requested_run_id}" ]]; then
  gh api --paginate --slurp "repos/${repo}/actions/workflows/quality.yml/runs?branch=staging-v2&event=workflow_dispatch&per_page=100" > "${temporary_dir}/runs.json" || {
    echo "Connected Payroll: certificate inventory unavailable; deployment held." >&2; exit 1;
  }
  requested_run_id="$(python3 "${validator}" certificate-run "${temporary_dir}/runs.json" "${payroll_sha}" "${aire_sha}")" || exit 1
fi
gh api "repos/${repo}/actions/runs/${requested_run_id}" > "${temporary_dir}/run.json"
run_attempt="$(python3 "${validator}" certificate-detail "${temporary_dir}/run.json" "${payroll_sha}" "${aire_sha}" "${requested_run_id}")"
gh run download "${requested_run_id}" --repo "${repo}" --name "connected-payroll-pair-${requested_run_id}-${run_attempt}" --dir "${temporary_dir}/certificate" >/dev/null
gh run download "${requested_run_id}" --repo "${repo}" --name "independent-payroll-producer-${requested_run_id}-${run_attempt}" --dir "${temporary_dir}/independent" >/dev/null
workflow_sha="$(python3 - "${temporary_dir}/run.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["head_sha"])
PY
)"
for evidence_file in producer.py verify_cornerstone.rb; do
  gh api "repos/${repo}/contents/scripts/connector_certification/${evidence_file}?ref=${workflow_sha}" > "${temporary_dir}/${evidence_file}.json"
done
python3 "${validator}" certificate "${temporary_dir}/run.json" "${temporary_dir}/certificate/pair-certificate.json" \
  "${temporary_dir}/independent/independent-producer-result.json" "${payroll_sha}" "${aire_sha}" \
  "${temporary_dir}/producer.py.json" "${temporary_dir}/verify_cornerstone.rb.json" > "${temporary_dir}/verified-run-id"
gh api "repos/${repo}/actions/runs/${requested_run_id}" > "${temporary_dir}/recheck.json"
python3 "${validator}" unchanged "${temporary_dir}/run.json" "${temporary_dir}/recheck.json"
if [[ "${automatic_certificate}" == 1 ]]; then
  gh api --paginate --slurp "repos/${repo}/actions/workflows/quality.yml/runs?branch=staging-v2&event=workflow_dispatch&per_page=100" > "${temporary_dir}/latest-runs.json" || {
    echo "Connected Payroll: final certificate inventory unavailable; deployment held." >&2; exit 1;
  }
  [[ "$(python3 "${validator}" certificate-run "${temporary_dir}/latest-runs.json" "${payroll_sha}" "${aire_sha}")" == "${requested_run_id}" ]] || {
    echo "Connected Payroll: newest certificate changed during verification; deployment held." >&2; exit 1;
  }
  python3 "${validator}" selection "${temporary_dir}/run.json" "${temporary_dir}/latest-runs.json"
fi
cat "${temporary_dir}/verified-run-id"
