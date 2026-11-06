# frozen_string_literal: true

namespace :db do
  desc "Verify the migration-defined PostgreSQL evidence guards"
  task integrity: :environment do
    DatabaseIntegrity.verify!
    puts "Payroll PostgreSQL integrity guards verified"
  end
end
