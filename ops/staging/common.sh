#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="${AIRE_PAYROLL_STAGING_SERVICE_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
COMPOSE_FILE="${SERVICE_DIR}/ops/staging/compose.yml"
RUNTIME_ENV_FILE="${AIRE_PAYROLL_STAGING_RUNTIME_ENV:-${SERVICE_DIR}/ops/staging/runtime.env}"
KEYCHAIN_ACCOUNT="${AIRE_PAYROLL_STAGING_KEYCHAIN_ACCOUNT:-aire-payroll-staging}"

if [[ -f "${RUNTIME_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${RUNTIME_ENV_FILE}"
  set +a
fi

export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima-aire-payroll-staging}"
export STAGING_BIND_ADDRESS="${STAGING_BIND_ADDRESS:-127.0.0.1}"
export AIRE_STAGING_PORT="${AIRE_STAGING_PORT:-8789}"
export PAYROLL_STAGING_PORT="${PAYROLL_STAGING_PORT:-8790}"

keychain_secret() {
  security find-generic-password -a "${KEYCHAIN_ACCOUNT}" -s "$1" -w
}

load_staging_secrets() {
  AIRE_POSTGRES_PASSWORD="$(keychain_secret aire-payroll-staging-aire-postgres)"
  PAYROLL_POSTGRES_PASSWORD="$(keychain_secret aire-payroll-staging-payroll-postgres)"
  AIRE_SECRET_KEY_BASE="$(keychain_secret aire-payroll-staging-aire-secret-key-base)"
  PAYROLL_SECRET_KEY_BASE="$(keychain_secret aire-payroll-staging-payroll-secret-key-base)"
  AIRE_ENCRYPTION_PRIMARY_KEY="$(keychain_secret aire-payroll-staging-aire-encryption-primary)"
  AIRE_ENCRYPTION_DETERMINISTIC_KEY="$(keychain_secret aire-payroll-staging-aire-encryption-deterministic)"
  AIRE_ENCRYPTION_KEY_DERIVATION_SALT="$(keychain_secret aire-payroll-staging-aire-encryption-salt)"
  PAYROLL_ENCRYPTION_PRIMARY_KEY="$(keychain_secret aire-payroll-staging-payroll-encryption-primary)"
  PAYROLL_ENCRYPTION_DETERMINISTIC_KEY="$(keychain_secret aire-payroll-staging-payroll-encryption-deterministic)"
  PAYROLL_ENCRYPTION_KEY_DERIVATION_SALT="$(keychain_secret aire-payroll-staging-payroll-encryption-salt)"
  AIRE_CLERK_SECRET_KEY="$(keychain_secret aire-payroll-staging-aire-clerk-secret)"
  PAYROLL_CLERK_SECRET_KEY="$(keychain_secret aire-payroll-staging-payroll-clerk-secret)"
  PAYROLL_CLERK_PUBLISHABLE_KEY="$(keychain_secret aire-payroll-staging-payroll-clerk-publishable)"
  PAYROLL_SHARED_SECRET="$(keychain_secret aire-payroll-staging-integration-secret)"
  export AIRE_POSTGRES_PASSWORD PAYROLL_POSTGRES_PASSWORD AIRE_SECRET_KEY_BASE PAYROLL_SECRET_KEY_BASE
  export AIRE_ENCRYPTION_PRIMARY_KEY AIRE_ENCRYPTION_DETERMINISTIC_KEY AIRE_ENCRYPTION_KEY_DERIVATION_SALT
  export PAYROLL_ENCRYPTION_PRIMARY_KEY PAYROLL_ENCRYPTION_DETERMINISTIC_KEY PAYROLL_ENCRYPTION_KEY_DERIVATION_SALT
  export AIRE_CLERK_SECRET_KEY PAYROLL_CLERK_SECRET_KEY PAYROLL_CLERK_PUBLISHABLE_KEY PAYROLL_SHARED_SECRET
}

validate_staging_configuration() {
  [[ "${AIRE_CLERK_SECRET_KEY}" == sk_test_* ]] || { echo "AIRE staging requires a Clerk test secret." >&2; return 1; }
  [[ "${PAYROLL_CLERK_SECRET_KEY}" == sk_test_* ]] || { echo "Payroll staging requires a Clerk test secret." >&2; return 1; }
  [[ "${PAYROLL_CLERK_PUBLISHABLE_KEY}" == pk_test_* ]] || { echo "Payroll staging requires a Clerk test publishable key." >&2; return 1; }
  [[ "${AIRE_PUBLIC_URL}" == https://* ]] || { echo "AIRE_PUBLIC_URL must use HTTPS." >&2; return 1; }
  [[ "${PAYROLL_PUBLIC_URL}" == https://* ]] || { echo "PAYROLL_PUBLIC_URL must use HTTPS." >&2; return 1; }
}

compose() {
  docker --context "${DOCKER_CONTEXT}" compose -f "${COMPOSE_FILE}" "$@"
}
