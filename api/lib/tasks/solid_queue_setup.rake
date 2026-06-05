# frozen_string_literal: true

namespace :solid_queue do
  REQUIRED_TABLES = %w[
    solid_queue_blocked_executions
    solid_queue_claimed_executions
    solid_queue_failed_executions
    solid_queue_jobs
    solid_queue_pauses
    solid_queue_processes
    solid_queue_ready_executions
    solid_queue_recurring_executions
    solid_queue_recurring_tasks
    solid_queue_scheduled_executions
    solid_queue_semaphores
  ].freeze

  desc "Ensure Solid Queue tables exist, loading queue schema if needed"
  task setup: :environment do
    schema_file = Rails.root.join("db/queue_schema.rb")

    unless schema_file.exist?
      puts "No queue schema file found at #{schema_file}, skipping."
      next
    end

    connection = ActiveRecord::Base.connection
    existing_tables = REQUIRED_TABLES.select { |table_name| connection.table_exists?(table_name) }
    missing_tables = REQUIRED_TABLES - existing_tables

    if missing_tables.empty?
      puts "Solid Queue tables already exist."
    elsif existing_tables.empty?
      puts "Solid Queue tables not found — loading db/queue_schema.rb..."
      load(schema_file)

      remaining_missing = REQUIRED_TABLES.reject { |table_name| connection.table_exists?(table_name) }
      raise "Solid Queue setup failed; missing tables after schema load: #{remaining_missing.join(', ')}" if remaining_missing.any?

      puts "Solid Queue tables created successfully."
    else
      raise "Partial Solid Queue schema detected; missing tables: #{missing_tables.join(', ')}. " \
            "Refusing to load db/queue_schema.rb because it uses force: :cascade and could reset existing queue data."
    end
  rescue => e
    warn "ERROR: Could not setup Solid Queue tables: #{e.class}: #{e.message}"
    raise
  end
end
