# frozen_string_literal: true

require_relative "../rls_task"

namespace :payroll_child_companies do
  desc "Backfill missing company IDs on promoted payroll children (BATCH_SIZE defaults to 1000)"
  RlsTask.system backfill: :environment do
    batch_size = ENV.fetch("BATCH_SIZE", PayrollChildCompanyBackfill::DEFAULT_BATCH_SIZE)
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      PayrollChildCompanyBackfill.new(connection: connection, batch_size: batch_size).backfill do |table, updated|
        puts "#{table}: updated=#{updated}"
      end
    end
  end

  desc "Check null company IDs and parent FK validity on promoted payroll children (read-only)"
  RlsTask.system verify: :environment do
    incomplete = false
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      PayrollChildCompanyBackfill.new(connection: connection).verify do |table, nulls, fk_state|
        puts "#{table}: nulls=#{nulls} parent_fk=#{fk_state}"
        incomplete ||= nulls.positive? || fk_state != "valid"
      end
    end
    abort "Payroll child company rollout is incomplete" if incomplete
  end
end
