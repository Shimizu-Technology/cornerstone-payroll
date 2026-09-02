# frozen_string_literal: true

require_relative "../database_predeploy"

namespace :db do
  desc "Removed unsafe task; use db:safe_prepare with direct migration connections"
  task :clear_advisory_locks do
    abort "[db:clear_advisory_locks] Removed because terminating shared database sessions is unsafe. Configure MIGRATION_DATABASE_URL and run db:safe_prepare."
  end

  desc "Prepare all production database schemas through direct database connections"
  task :safe_prepare do
    DatabasePredeploy.new.run!
  rescue DatabasePredeploy::ConfigurationError => e
    abort "[db:safe_prepare] #{e.message}"
  end
end
