# frozen_string_literal: true

require_relative "support/m3_7_child_companies"

# M3-7 contract: every promoted child row has its company. A validated CHECK
# lets SET NOT NULL skip its full-table scan, so each table holds an
# exclusive lock only for catalog changes. The fill triggers stay: they
# supply company_id before PostgreSQL checks NOT NULL.
class ContractPayrollChildCompanies < ActiveRecord::Migration[8.1]
  include M3_7ChildCompanies
  disable_ddl_transaction!

  class MissingCompanyError < StandardError; end

  LOCK_ATTEMPTS = 3

  def up
    refuse_missing_companies!
    CHILDREN.each_key do |table|
      next if company_required?(table)

      constraint = check_name(table)
      with_lock_retries do
        unless check_exists?(table)
          execute "ALTER TABLE #{table} ADD CONSTRAINT #{constraint} CHECK (company_id IS NOT NULL) NOT VALID"
        end
      end
      # VALIDATE takes SHARE UPDATE EXCLUSIVE, so reads and writes continue.
      with_lock_retries do
        execute "ALTER TABLE #{table} VALIDATE CONSTRAINT #{constraint}"
      rescue ActiveRecord::CheckViolation
        raise MissingCompanyError, missing_message([ table ])
      end
      with_lock_retries do
        execute "ALTER TABLE #{table} ALTER COLUMN company_id SET NOT NULL"
        execute "ALTER TABLE #{table} DROP CONSTRAINT #{constraint}"
      end
    end
  end

  def down
    CHILDREN.each_key do |table|
      with_short_ddl_transaction do
        execute "ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{check_name(table)}"
        execute "ALTER TABLE #{table} ALTER COLUMN company_id DROP NOT NULL"
      end
    end
  end

  private

  # A long query on a busy table fails one short lock wait, not the deploy.
  def with_lock_retries(&block)
    attempts = 0
    begin
      with_short_ddl_transaction(&block)
    rescue ActiveRecord::LockWaitTimeout
      attempts += 1
      raise if attempts >= LOCK_ATTEMPTS

      sleep(attempts)
      retry
    end
  end

  def refuse_missing_companies!
    missing = CHILDREN.keys.select do |table|
      !company_required?(table) && select_value("SELECT EXISTS (SELECT 1 FROM #{table} WHERE company_id IS NULL)")
    end
    raise MissingCompanyError, missing_message(missing) if missing.any?
  end

  def missing_message(tables)
    "company_id is NULL on #{tables.join(', ')}. Backfill each row from its parent " \
      "(db/migrate/support/m3_7_child_companies.rb) before requiring it."
  end

  def check_name(table)
    "#{table}_company_id_present"
  end

  def company_required?(table)
    columns(table).find { |column| column.name == "company_id" }&.null == false
  end

  def check_exists?(table)
    select_value(<<~SQL)
      SELECT EXISTS (SELECT 1 FROM pg_constraint
        WHERE conrelid = #{quote(table.to_s)}::regclass AND conname = #{quote(check_name(table))})
    SQL
  end
end
