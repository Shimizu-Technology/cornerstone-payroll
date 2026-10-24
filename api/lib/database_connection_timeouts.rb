# frozen_string_literal: true

# Canonical predeploy session limits. No routing, role or search-path options.
module DatabaseConnectionTimeouts
  PG_OPTIONS = "-c lock_timeout=10s -c statement_timeout=15min -c idle_in_transaction_session_timeout=5min".freeze
end
