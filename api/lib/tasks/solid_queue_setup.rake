# frozen_string_literal: true

namespace :solid_queue do
  desc "Ensure Solid Queue tables exist, loading queue schema if needed"
  task setup: :environment do
    schema_file = Rails.root.join("db/queue_schema.rb")

    unless schema_file.exist?
      puts "No queue schema file found at #{schema_file}, skipping."
      next
    end

    connection = ActiveRecord::Base.connection

    if connection.table_exists?("solid_queue_jobs")
      puts "Solid Queue tables already exist."
    else
      puts "Solid Queue tables not found — loading db/queue_schema.rb..."
      load(schema_file)
      puts "Solid Queue tables created successfully."
    end
  rescue => e
    warn "WARNING: Could not setup Solid Queue tables: #{e.class}: #{e.message}"
  end
end
